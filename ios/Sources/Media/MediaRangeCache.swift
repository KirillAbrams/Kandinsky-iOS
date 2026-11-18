// Хранит части видео на диске и выдаёт проигрывателю только нужные байты. После повторного
// открытия готовые части используются снова, а полный файл появляется после проверки.

import Foundation
import CryptoKit

/// Части на диске переживают отмену, а собранный оригинал появляется только после необходимых проверок.
final class MediaRangeCache: @unchecked Sendable {
  static let chunkSize = 256 * 1024
  let length: Int64
  private let directory: URL, original: URL, blob: String
  private let fetch: (Int64, Int64, MediaCancellation) throws -> Data
  private let onPromoted: (@Sendable () -> Void)?
  private let io = NSLock(), state = NSLock()
  private var closed = false, active: MediaCancellation?
  private var memory: [Int: Data] = [:], order: [Int] = []
  // Проверяет номер, длину файла и путь без ссылок. Создаёт отдельную папку для частей, чтобы
  // неверное имя не направило запись в чужое место.
  init(
    root: URL, blob: String, length: Int64, original: URL,
    onPromoted: (@Sendable () -> Void)? = nil,
    fetch: @escaping (Int64, Int64, MediaCancellation) throws -> Data
  ) throws {
    guard [32, 64].contains(blob.count), blob.allSatisfy({ "0123456789abcdef".contains($0) }),
      (1...67108864).contains(length)
    else { throw MediaError.corrupt }
    self.blob = blob
    self.length = length
    self.original = original
    self.onPromoted = onPromoted
    self.fetch = fetch
    directory = root.appendingPathComponent("media/ranges/" + blob)
    guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
      throw MediaError.corrupt
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  /// Скачанные части остаются на диске. Если снова открыть видео, плеер сможет использовать их без повторной
  /// загрузки.
  // Читает из полного файла, памяти или сохранённой части, а недостающую загружает и проверяет.
  // Возвращает ограниченную порцию байтов и оставляет только две части в памяти, чтобы
  // проигрыватель не держал там весь ролик.
  func read(offset: Int64, count: Int, cancellation: MediaCancellation) throws -> Data {
    guard offset >= 0, count >= 0 else { throw MediaError.corrupt }
    if offset >= length || count == 0 { return Data() }
    io.lock()
    defer {
      state.lock()
      let stopped = closed
      state.unlock()
      if stopped {
        memory.removeAll()
        order.removeAll()
      }
      io.unlock()
    }
    state.lock()
    let stopped = closed
    state.unlock()
    guard !stopped, !cancellation.isCancelled else { throw MediaError.cancelled }
    if FileManager.default.fileExists(atPath: original.path) {
      let file = try FileHandle(forReadingFrom: original)
      defer { try? file.close() }
      try file.seek(toOffset: UInt64(offset))
      return try file.read(upToCount: min(count, 65536, Int(length - offset))) ?? Data()
    }
    let index = Int(offset / Int64(Self.chunkSize)), start = Int64(index * Self.chunkSize),
      size = Int(min(Int64(Self.chunkSize), length - start))
    let data: Data
    if let cached = memory[index] {
      data = cached
    } else {
      let path = directory.appendingPathComponent(String(index) + ".chunk")
      if let sizeOnDisk = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        sizeOnDisk == size
      {
        data = try Data(contentsOf: path)
      } else {
        let token = MediaCancellation()
        state.lock()
        active = token
        let closedNow = closed
        state.unlock()
        cancellation.onCancel { token.cancel() }
        if closedNow || cancellation.isCancelled { token.cancel() }
        defer {
          state.lock()
          if active === token { active = nil }
          state.unlock()
        }
        data = try fetch(start, start + Int64(size) - 1, token)
        guard !token.isCancelled, data.count == size else { throw MediaError.corrupt }
        try data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes(
          [.modificationDate: Date()], ofItemAtPath: directory.path)
        try promoteIfComplete()
        pruneInactive()
      }
      memory[index] = data
    }
    order.removeAll { $0 == index }
    order.append(index)
    while order.count > 2 { memory.removeValue(forKey: order.removeFirst()) }
    let local = Int(offset - start), amount = min(count, 65536, data.count - local)
    return data.subdata(in: local..<local + amount)
  }
  /// Если номер файла содержит полный хеш, сверяем его перед публикацией. Повреждённые части придётся
  /// скачать заново.
  // Проверяет наличие и длину всех частей, собирает временный файл и при наличии сверяет
  // контрольную сумму. Только после этого переносит оригинал на постоянный путь и удаляет части.
  private func promoteIfComplete() throws {
    let count = Int((length + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize)),
      fm = FileManager.default
    guard !fm.fileExists(atPath: original.path) else { return }
    for i in 0..<count {
      let expected = Int(min(Int64(Self.chunkSize), length - Int64(i * Self.chunkSize)))
      guard
        (try? directory.appendingPathComponent(String(i) + ".chunk").resourceValues(forKeys: [
          .fileSizeKey
        ]).fileSize) == expected
      else { return }
    }
    try fm.createDirectory(
      at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = original.deletingLastPathComponent().appendingPathComponent(
      "range-" + UUID().uuidString + ".part")
    fm.createFile(atPath: temp.path, contents: nil)
    defer { try? fm.removeItem(at: temp) }
    let output = try FileHandle(forWritingTo: temp)
    var digest = SHA256()
    do {
      for i in 0..<count {
        state.lock()
        let stopped = closed
        state.unlock()
        if stopped { throw MediaError.cancelled }
        let data = try Data(contentsOf: directory.appendingPathComponent(String(i) + ".chunk"))
        digest.update(data: data)
        try output.write(contentsOf: data)
      }
      try output.synchronize()
      try output.close()
    } catch {
      try? output.close()
      throw error
    }
    if blob.count == 64, digest.finalize().map({ String(format: "%02x", $0) }).joined() != blob {
      for i in 0..<count {
        try? fm.removeItem(at: directory.appendingPathComponent(String(i) + ".chunk"))
      }
      memory.removeAll()
      order.removeAll()
      throw MediaError.corrupt
    }
    if !fm.fileExists(atPath: original.path) {
      try fm.moveItem(at: temp, to: original)
      onPromoted?()
    }
    for i in 0..<count {
      try? fm.removeItem(at: directory.appendingPathComponent(String(i) + ".chunk"))
    }
  }
  /// Текущий файл может ещё читать плеер. Поэтому при нехватке места удаляем части других файлов.
  // Считает занятое место частями и начинает уборку со старых папок других файлов. Текущие части
  // оставляет, чтобы проигрыватель мог продолжить чтение.
  private func pruneInactive() {
    let fm = FileManager.default, parent = directory.deletingLastPathComponent()
    let dirs =
      (try? fm.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let sizes = dirs.map { dir -> (URL, Int, Date) in
      let files =
        (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
      return (
        dir,
        files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) },
        (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
      )
    }
    var total = sizes.reduce(0) { $0 + $1.1 }
    for (dir, size, _) in sizes.sorted(by: { $0.2 < $1.2 })
    where total > 64 * 1024 * 1024 && dir != directory {
      if (try? fm.removeItem(at: dir)) != nil { total -= size }
    }
  }
  // Помечает источник закрытым и отменяет активную загрузку. Если чтение ещё держит блокировку,
  // оно само освободит память при выходе. Так закрытие не ждёт сетевой ответ.
  func close() {
    state.lock()
    closed = true
    let pending = active
    active = nil
    state.unlock()
    pending?.cancel()
    if io.try() {
      memory.removeAll()
      order.removeAll()
      io.unlock()
    }
  }
  // Закрывает источник при освобождении владельца. Незавершённая передача не должна пережить
  // объект, который получал её результат.
  deinit { close() }
}
