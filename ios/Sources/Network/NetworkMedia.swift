// Находит скачанные оригиналы и уменьшенные копии, выдаёт файлы для просмотра и освобождает
// место. Для видео умеет получать по сети отдельные отрезки, пока целого файла ещё нет.

import CryptoKit
import Foundation

private final class NetworkCacheReadPin: @unchecked Sendable {
  private let lock = NSLock()
  private var release: (() -> Void)?
  // Запоминает способ освободить файл после чтения. Это позволяет месту загрузки и месту чтения
  // пользоваться одним счётчиком.
  init(release: @escaping () -> Void) { self.release = release }
  // Забирает действие освобождения под блокировкой и вызывает его только один раз. Повторное
  // закрытие не уменьшит число активных чтений ещё раз.
  func close() {
    lock.lock()
    let action = release
    release = nil
    lock.unlock()
    action?()
  }
  // Освобождает удержание при уничтожении записи чтения. Иначе забытый вызов закрытия оставил бы
  // файл защищённым от очистки.
  deinit { close() }
}

private final class NetworkFileResult: @unchecked Sendable {
  private let lock = NSLock(), ready = DispatchSemaphore(value: 0)
  private var result: Result<(URL, String), Error>?
  /// После записи результата пробуждает ожидающее чтение, чтобы оно получило либо данные, либо исходную
  /// ошибку.
  // Сохраняет готовый путь или исходную ошибку под блокировкой, затем будит ожидающее чтение.
  // Ожидание получает результат целиком, когда запись закончена.
  func complete(_ value: Result<(URL, String), Error>) {
    lock.lock()
    result = value
    lock.unlock()
    ready.signal()
  }
  // Ждёт путь или ошибку с ограничением времени и читает итог под той же блокировкой. Сбой
  // загрузки не удерживает место чтения бесконечно.
  func wait() throws -> (URL, String) {
    guard ready.wait(timeout: .now() + 95) == .success else { throw MediaError.io }
    lock.lock()
    defer { lock.unlock() }
    return try result!.get()
  }
}
struct StudioMediaRemoval: Sendable {
  static let prefix = "studioRemoved:"
  let blob: String, preview: String
  var key: String { Self.prefix + blob }
  // Принимает удаление, только если оба номера имеют правильные длину и вид. Иначе отметка могла
  // бы указать на посторонний файл.
  init?(blob: String, preview: String) {
    guard blob.count == 32, preview.count == 32,
      RemoteMediaLocation.validBlobID(blob), RemoteMediaLocation.validBlobID(preview)
    else { return nil }
    self.blob = blob
    self.preview = preview
  }
}

final class NetworkMedia: MediaFileProvider, @unchecked Sendable {
  private let store: SQLiteStore, api: NetworkAPI
  private let diskBudget: NetworkDiskBudget, previewDiskBudget: NetworkDiskBudget
  private let downloads = NSLock(), migration = NSLock(), pinGate = NSLock()
  private var pins: [String: Int] = [:]
  private var revoked = Set<String>()
  /// Останавливает чтение отменой, чтобы сохранённая копия не вернула удалённый результат в историю.
  // Сверяет начало имени с кратким списком отозванных результатов. При совпадении прерывает новое
  // чтение, чтобы оно не вернуло уже удалённое из местной копии.
  private func requireAvailable(_ name: String) throws {
    let blob = String(name.prefix(32))
    pinGate.lock()
    let removed = revoked.contains(blob)
    pinGate.unlock()
    if removed { throw MediaError.cancelled }
  }
  /// После удаления сбрасывает учёт занятого места, чтобы последующая проверка пересчитала его по диску.
  // Сначала отмечает отзыв, затем ждёт текущую загрузку и убирает оригинал, уменьшенные копии и
  // сохранённые отрезки. После очистки сбрасывает подсчёт места, иначе следующий расчёт опирался
  // бы на старый объём.
  func removeCached(_ removal: StudioMediaRemoval) throws {
    pinGate.lock()
    revoked.insert(removal.blob)
    if revoked.count > 512, let old = revoked.first(where: { $0 != removal.blob }) {
      revoked.remove(old)
    }
    pinGate.unlock()
    downloads.lock()
    defer {
      downloads.unlock()
      diskBudget.invalidate()
      previewDiskBudget.invalidate()
    }
    let fm = FileManager.default
    let directory = try MediaStore.fileURL(root: store.root, relative: "remote")
    let files = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    var filenames = Set(files.filter { $0 == removal.blob || $0.hasPrefix(removal.blob + ".") })
    for ext in ["jpg", "png", "gif", "heic", "heif", "mp4", "mov", "webp", "bin"] {
      filenames.insert(removal.blob + "." + ext)
    }
    for name in filenames.union([removal.blob]) {
      let relative = "remote/" + name
      try VideoCoverDiskCache.revoke(root: store.root, relativePath: relative)
      let original = try MediaStore.fileURL(root: store.root, relative: relative)
      let derived = try MediaStore.fileURL(
        root: store.root, relative: "previews/" + MediaPreviewGenerator.derivedName(relative))
      for file in [original, derived] where fm.fileExists(atPath: file.path) {
        try fm.removeItem(at: file)
      }
    }
    for path in [
      "previews/" + removal.preview + ".jpg", "previews/" + removal.preview,
      "ranges/" + removal.blob,
    ] {
      let file = try MediaStore.fileURL(root: store.root, relative: path)
      if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }
  }
  // Связывает файлы с базой и сетью и выбирает отдельные пределы для оригиналов и уменьшенных
  // копий. Для проверки можно задать общий подсчёт.
  init(
    store: SQLiteStore, api: NetworkAPI, diskBudget: NetworkDiskBudget? = nil,
    originalLimitMiB: Int = 64
  ) {
    self.store = store
    self.api = api
    self.diskBudget =
      diskBudget
      ?? NetworkDiskBudget(root: store.root, scope: .originals, originalLimitMiB: originalLimitMiB)
    self.previewDiskBudget = diskBudget ?? NetworkDiskBudget(root: store.root, scope: .previews)
  }
  // Ищет готовый файл до ожидания чужой загрузки и снова после него. При отсутствии сверяет
  // сетевые номера и выбирает оригинал или маленькую копию, скачивает, учитывает занятое место и
  // удерживает файл до конца чтения.
  func resolve(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws -> (
    URL, String
  ) {
    precondition(!Thread.isMainThread)
    if token.isCancelled { throw MediaError.cancelled }
    try requireAvailable(String(attachment.relativePath.dropFirst("remote/".count)))
    let (originalRelative, knownLocation) = try cacheLocation(attachment)
    if let file = try cachedFile(
      attachment, relative: originalRelative, preview: preview, location: knownLocation, token: token
    ) { return file }
    // После допуска проверяем снова, поскольку прежний запрос мог уже сохранить нужную копию.
    downloads.lock()
    defer { downloads.unlock() }
    if token.isCancelled { throw MediaError.cancelled }
    try requireAvailable(String(attachment.relativePath.dropFirst("remote/".count)))
    if let cached = try cachedFile(
      attachment, relative: originalRelative, preview: preview, location: knownLocation,
      token: token)
    {
      return cached
    }
    let targetOriginalRelative = originalRelative
    let result = NetworkFileResult()
    let store = self.store
    let api = self.api
    let task = Task.detached(priority: .utility) {
      var unaccountedTarget: URL?
      do {
        let mapping: (String, String?, Int64)
        if let knownLocation {
          mapping = (knownLocation.blobID, knownLocation.previewBlobID, knownLocation.byteSize)
        } else {
          mapping = try await store.perform { db -> (String, String?, Int64) in
            guard
              let row = try db.rows(
                "SELECT blobID,previewBlobID,byteSize FROM net_media WHERE attachmentID=?",
                [.text(attachment.id)]
              ).first
            else { throw RepoError.notFound }
            let small: String? = row["previewBlobID"].flatMap {
              if case .text(let s) = $0 { return s }
              return nil
            }
            return (row["blobID"]!.string, small, row["byteSize"]!.int)
          }
        }
        try Task.checkCancellation()
        guard RemoteMediaLocation.validBlobID(mapping.0),
          mapping.1.map(RemoteMediaLocation.validBlobID) ?? true
        else { throw MediaError.corrupt }
        guard
          attachment.relativePath == Self.relativePath(blob: mapping.0, mime: attachment.mime)
            || attachment.relativePath == "remote/" + mapping.0
        else { throw MediaError.cancelled }
        guard !preview || mapping.1 != nil || mapping.2 <= 256 * 1024 else {
          throw MediaError.unavailable
        }
        let usePreview = preview && mapping.1 != nil
        let blob = usePreview ? mapping.1! : mapping.0
        let target =
          usePreview ? try self.previewFile(blob) : try self.localFile(targetOriginalRelative)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if !existed { unaccountedTarget = target }
        try await api.download(
          blob: blob, to: target, limit: usePreview ? 256 * 1024 : mapping.2,
          progress: { token.reportProgress($0) })
        let added =
          existed ? 0 : ((try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // Учитываем завершённую запись, даже если сразу после неё вызывающая сторона отменит запрос
        try self.prune(keep: target, addedBytes: added)
        unaccountedTarget = nil
        try Task.checkCancellation()
        result.complete(.success((target, usePreview ? "image/jpeg" : attachment.mime)))
      } catch {
        if let target = unaccountedTarget, FileManager.default.fileExists(atPath: target.path) {
          self.budget(for: target).invalidate()
        }
        result.complete(.failure(error))
      }
    }
    token.onCancel { task.cancel() }
    if token.isCancelled { task.cancel() }
    let resolved = try result.wait()
    let lease = NetworkCacheReadPin(release: pin(resolved.0))
    guard FileManager.default.fileExists(atPath: resolved.0.path) else {
      throw MediaError.unavailable
    }
    try retainRead(lease, for: token)
    return resolved
  }
  /// Проверяет местную копию без ожидания чужой сетевой загрузки.
  // Проверяет отмену и отзыв, затем ищет только местную копию. Это позволяет показать готовое
  // сразу, пока другая фоновая работа ещё ждёт сеть.
  func cached(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws -> (URL, String)? {
    precondition(!Thread.isMainThread)
    if token.isCancelled { throw MediaError.cancelled }
    try requireAvailable(String(attachment.relativePath.dropFirst("remote/".count)))
    let (relative, location) = try cacheLocation(attachment)
    return try cachedFile(attachment, relative: relative, preview: preview, location: location, token: token)
  }
  // Находит путь со старым или новым именем и при необходимости добавляет расширение без
  // перезаписи существующей копии. Принимает готовое сетевое описание, только если путь, тип и
  // размер совпали.
  private func cacheLocation(_ attachment: Attachment) throws -> (String, RemoteMediaLocation?) {
    var originalRelative = attachment.relativePath
    let original = store.root.appendingPathComponent("media/" + originalRelative)
    if attachment.relativePath.hasPrefix("remote/"), original.pathExtension.isEmpty {
      migration.lock()
      defer { migration.unlock() }
      let typed = original.appendingPathExtension(Self.fileExtension(attachment.mime))
      let typedRelative = originalRelative + "." + Self.fileExtension(attachment.mime)
      if FileManager.default.fileExists(atPath: original.path),
        !FileManager.default.fileExists(atPath: typed.path)
      {
        _ = try localFile(originalRelative)
        _ = try localFile(typedRelative)
        try FileManager.default.moveItem(at: original, to: typed)
      }
      originalRelative = typedRelative
    }
    let knownLocation = attachment.remoteLocation.flatMap { location -> RemoteMediaLocation? in
      guard location.isValid, location.mime == attachment.mime,
        location.byteSize == attachment.byteSize,
        attachment.relativePath == Self.relativePath(blob: location.blobID, mime: attachment.mime)
          || attachment.relativePath == "remote/" + location.blobID
      else { return nil }
      return location
    }
    return (originalRelative, knownLocation)
  }
  // Освобождает файл по сигналу отмены и сразу проверяет, был ли этот сигнал уже дан. Иначе
  // чтение могло бы начаться после закрытия.
  private func retainRead(_ lease: NetworkCacheReadPin, for token: MediaCancellation) throws {
    token.onCancel { lease.close() }
    if token.isCancelled { throw MediaError.cancelled }
  }
  // Сначала пытается закрепить готовый оригинал, затем при запросе миниатюры пробует её отдельный
  // файл. Отмечает время использования, чтобы недавно прочитанную копию не убрали первой.
  private func cachedFile(
    _ attachment: Attachment, relative: String, preview: Bool, location: RemoteMediaLocation?,
    token: MediaCancellation
  ) throws -> (URL, String)? {
    let original = store.root.appendingPathComponent("media/" + relative)
    do {
      let lease = NetworkCacheReadPin(release: pin(original))
      if FileManager.default.fileExists(atPath: original.path) {
        let file = try localFile(relative)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try retainRead(lease, for: token)
        return (file, attachment.mime)
      }
    }
    guard attachment.relativePath.hasPrefix("remote/") else { throw MediaError.io }
    if preview, let blob = location?.previewBlobID {
      let file = try previewFile(blob)
      let lease = NetworkCacheReadPin(release: pin(file))
      if FileManager.default.fileExists(atPath: file.path) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try prune(keep: file)
        try retainRead(lease, for: token)
        return (file, "image/jpeg")
      }
    }
    return nil
  }
  // Строит путь сетевой миниатюры отдельно от оригинала. Это сохраняет разницу качества и
  // назначения двух файлов.
  private func previewFile(_ blob: String) throws -> URL {
    try localFile("previews/" + blob + ".jpg")
  }
  // Проверяет допустимость относительного пути и возвращает путь внутри папки медиа. Без проверки
  // неверное имя могло бы направить чтение в другое место.
  private func localFile(_ relative: String) throws -> URL {
    _ = try MediaStore.fileURL(root: store.root, relative: relative)
    return store.root.appendingPathComponent("media/" + relative)
  }
  // Отдаёт местный файл, если он уже есть, иначе читает номер и длину из базы и готовит отрезки
  // для проигрывателя. Удерживает исходник до закрытия, а отозванный файл перестаёт передавать
  // куски.
  func playback(_ attachment: Attachment, token: MediaCancellation) throws -> MediaPlaybackSource {
    precondition(!Thread.isMainThread)
    try requireAvailable(String(attachment.relativePath.dropFirst("remote/".count)))
    var file = store.root.appendingPathComponent("media/" + attachment.relativePath)
    if attachment.relativePath.hasPrefix("remote/"), file.pathExtension.isEmpty {
      let typed = file.appendingPathExtension(Self.fileExtension(attachment.mime))
      migration.lock()
      defer { migration.unlock() }
      if FileManager.default.fileExists(atPath: file.path),
        !FileManager.default.fileExists(atPath: typed.path)
      {
        try FileManager.default.moveItem(at: file, to: typed)
      }
      file = typed
    }
    let release = pin(file)
    var transferred = false
    defer { if !transferred { release() } }
    if FileManager.default.fileExists(atPath: file.path) {
      transferred = true
      return MediaPlaybackSource(file: file, onClose: release)
    }
    guard attachment.relativePath.hasPrefix("remote/"), !token.isCancelled else {
      throw MediaError.io
    }
    let result = NetworkPlaybackMapping()
    let store = self.store
    Task.detached {
      do {
        let value = try await store.perform { db -> (String, Int64) in
          guard
            let row = try db.rows(
              "SELECT blobID,byteSize FROM net_media WHERE attachmentID=?", [.text(attachment.id)]
            ).first
          else { throw RepoError.notFound }
          return (row["blobID"]!.string, row["byteSize"]!.int)
        }
        result.complete(.success(value))
      } catch { result.complete(.failure(error)) }
    }
    let (blob, size) = try result.wait()
    if token.isCancelled { throw MediaError.cancelled }
    let api = self.api
    let budget = self.diskBudget
    let cache = try MediaRangeCache(
      root: store.root, blob: blob, length: size, original: file,
      onPromoted: { budget.recordWrite(bytes: Int(size)) }
    ) { [weak self] start, end, request in
      guard let self else { throw MediaError.cancelled }
      try self.requireAvailable(blob)
      let data = try api.range(blob: blob, start: start, end: end, length: size, token: request)
      try self.requireAvailable(blob)
      return data
    }
    transferred = true
    return MediaPlaybackSource(cache: cache, mime: attachment.mime, blob: blob, onClose: release)
  }
  /// Увеличивает число использований файла, чтобы очистка диска не удалила его во время чтения.
  // Увеличивает счётчик чтений по пути и возвращает действие для его уменьшения. Очистка
  // пропускает файл, пока он нужен хотя бы одному читателю.
  private func pin(_ file: URL) -> () -> Void {
    let path = file.standardizedFileURL.path
    pinGate.lock()
    pins[path, default: 0] += 1
    pinGate.unlock()
    return { [weak self] in
      guard let self else { return }
      self.pinGate.lock()
      let count = (self.pins[path] ?? 1) - 1
      if count == 0 { self.pins.removeValue(forKey: path) } else { self.pins[path] = count }
      self.pinGate.unlock()
    }
  }
  // Определяет, относится ли путь к отдельной папке уменьшенных копий. Так небольшие изображения
  // учитываются по своему пределу.
  private func budget(for file: URL) -> NetworkDiskBudget {
    file.deletingLastPathComponent().standardizedFileURL
      == store.root.appendingPathComponent("media/previews").standardizedFileURL
      ? previewDiskBudget : diskBudget
  }
  // Передаёт новые байты подсчёту и разрешает удалить только файлы без активных чтений. Когда
  // принята миниатюра, проверяет и предел оригиналов.
  private func prune(keep: URL, addedBytes: Int = 0) throws {
    let remove: (URL) throws -> Bool = { file in
      self.pinGate.lock()
      defer { self.pinGate.unlock() }
      guard self.pins[file.standardizedFileURL.path] == nil else { return false }
      try FileManager.default.removeItem(at: file)
      return true
    }
    let current = budget(for: keep)
    try current.accept(keep: keep, addedBytes: addedBytes, remove: remove)
    if current !== diskBudget { try diskBudget.accept(keep: keep, remove: remove) }
  }
  // Выбирает расширение по известному типу файла и использует общее расширение для остальных. Это
  // даёт постоянный путь для повторного поиска.
  static func fileExtension(_ mime: String) -> String {
    [
      "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/heic": "heic",
      "image/heif": "heif", "video/mp4": "mp4", "video/quicktime": "mov", "audio/mp4": "m4a",
    ][mime] ?? "bin"
  }
  /// Использует постоянный номер содержимого и расширение его вида, чтобы повторные обращения находили ту
  /// же местную копию.
  // Строит имя оригинала из номера его содержимого и расширения. Один сетевой файл при повторном
  // открытии находится по тому же пути.
  static func relativePath(blob: String, mime: String) -> String {
    "remote/" + blob + "." + fileExtension(mime)
  }
  /// Возвращает разные пути их вложений, чтобы восстановление и очистка учитывали ещё нужные местные
  /// исходники.
  // Собирает пути вложений из черновика и очереди отправки. Эти файлы ещё нужны, даже если пока
  // не попали в опубликованную историю.
  static func pendingReferences(_ db: SQLiteConnection) throws -> Set<String> {
    var paths: Set<String> = []
    if let pending = try StudioDraftStorage.load(db) {
      paths.formUnion(pending.draft.attachmentDrafts.map(\.relativePath))
      for command in pending.draft.pendingMediaBatch ?? [] {
        paths.formUnion(command.attachments.map(\.relativePath))
      }
      if let command = pending.draft.pendingSend {
        paths.formUnion(command.attachments.map(\.relativePath))
      }
    }
    for row in try db.rows("SELECT payload FROM net_outbox WHERE action='send'") {
      let command = try JSONDecoder().decode(
        SendCommand.self, from: Data(row["payload"]!.string.utf8))
      for attachment in command.attachments { paths.insert(attachment.relativePath) }
    }
    return paths
  }
}

final class NetworkDiskBudget: @unchecked Sendable {
  enum Scope {
    case combined, originals, previews
    var directories: [String] {
      switch self {
      case .combined: return ["remote", "previews"]
      case .originals: return ["remote"]
      case .previews: return ["previews"]
      }
    }
  }
  private let root: URL, fileManager: FileManager, lock = NSLock()
  private var knownBytes: Int?
  private let scope: Scope, limit: Int, target: Int
  /// Целевой объём очистки оставляет на восемь мегабайт ниже предела, чтобы после освобождения появился
  /// запас места.
  // Выбирает папки и предел размера. Цель очистки на восемь мебибайт ниже предела, чтобы после
  // удаления оставалось место для следующих файлов.
  init(
    root: URL, fileManager: FileManager = .default, scope: Scope = .combined,
    originalLimitMiB: Int = 64
  ) {
    self.root = root
    self.fileManager = fileManager
    self.scope = scope
    // Запас уменьшенных копий должен переживать появление гораздо более крупных оригиналов.
    let limitMiB = scope == .previews ? 96 : originalLimitMiB
    self.limit = limitMiB * 1024 * 1024
    self.target = (limitMiB - 8) * 1024 * 1024
  }
  // Сбрасывает сохранённый подсчёт под блокировкой. Следующая проверка пересчитает папку, если
  // объём изменился вне учёта.
  func invalidate() {
    lock.lock()
    knownBytes = nil
    lock.unlock()
  }
  // Добавляет байты к известному объёму без перечитывания папки. При неверном размере или
  // переполнении сбрасывает подсчёт, чтобы не пользоваться неверным итогом.
  func recordWrite(bytes: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard bytes >= 0 else {
      knownBytes = nil
      return
    }
    if let knownBytes {
      let (total, overflow) = knownBytes.addingReportingOverflow(bytes)
      self.knownBytes = overflow ? nil : total
    }
  }
  // При небольшом добавлении обновляет известный объём. Если предел превышен или подсчёта нет,
  // перечитывает файлы и удаляет старые до целевого объёма, пропуская нужный файл и занятые
  // чтением.
  func accept(keep: URL, addedBytes: Int = 0, remove: (URL) throws -> Bool) throws {
    lock.lock()
    defer { lock.unlock() }
    guard addedBytes >= 0 else { throw MediaError.corrupt }
    if let knownBytes {
      let (total, overflow) = knownBytes.addingReportingOverflow(addedBytes)
      if !overflow, total <= limit {
        self.knownBytes = total
        return
      }
    }
    knownBytes = nil
    let files = scope.directories.flatMap { name in
      (try? fileManager.contentsOfDirectory(
        at: root.appendingPathComponent("media/" + name),
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]))
        ?? []
    }.compactMap { url -> (URL, Int, Date)? in
      guard
        let value = try? url.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
        ]), value.isRegularFile == true
      else { return nil }
      return (url, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
    }
    var bytes = files.reduce(0) { $0 + $1.1 }
    if bytes > limit {
      for (file, size, _) in files.sorted(by: { $0.2 < $1.2 }) where bytes > target && file != keep
      {
        if try remove(file) { bytes -= size }
      }
    }
    knownBytes = bytes
  }
}

private final class NetworkPlaybackMapping: @unchecked Sendable {
  private let ready = DispatchSemaphore(value: 0)
  private var result: Result<(String, Int64), Error>?
  /// После записи результата пробуждает ожидающее чтение, чтобы оно получило либо данные, либо исходную
  /// ошибку.
  // Сохраняет номер файла и длину или ошибку базы, затем будит чтение видео. Так открытие ждёт
  // готового описания для запроса отрезков.
  func complete(_ value: Result<(String, Int64), Error>) {
    result = value
    ready.signal()
  }
  // Возвращает описание исходника или ошибку и прекращает ожидание через десять секунд. Без
  // предела открытие видео зависело бы от задержки базы.
  func wait() throws -> (String, Int64) {
    guard ready.wait(timeout: .now() + 10) == .success else { throw MediaError.io }
    return try result!.get()
  }
}
