import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Darwin
@MainActor final class MediaStore {
  let store: SQLiteStore
  private let studioOriginals: Bool
  private let mediaDecodeQueue = MediaDecodeQueue()
  private let tinyPreviewQueue = MediaDecodeQueue(maximumWorkers: 1)
  private let imageWorkQueue = MediaImageWorkQueue()
  private let thumbnailRequests = MediaThumbnailRequests()
  private let imageMemoryBudget = ImageByteBudget()
  private lazy var tinyPreviewCache = ThumbnailCache(budget: imageMemoryBudget, entryLimit: 64)
  private lazy var galleryDisk = VideoCoverDiskCache(root: store.root)
  private var seenGalleryPaths: [String] = []
  lazy var videoPlayback = VideoPlaybackCache(budget: imageMemoryBudget, root: store.root)
  private let videoPreparation = MediaVideoPreparation()
  private lazy var thumbnailCache = ThumbnailCache(
    budget: imageMemoryBudget, entryLimit: studioOriginals ? 48 : 16,
    navigationBytes: (studioOriginals ? 32 : 8) * 1024 * 1024)
  var remotePlayback: ((Attachment, MediaCancellation) throws -> MediaPlaybackSource)?
  var remoteFile: ((Attachment, Bool, MediaCancellation) throws -> (URL, String))?
  var remoteThumbnailProvider: (any MediaFileProvider)?
  var pendingReferences: ((SQLiteConnection) throws -> Set<String>)?
  private var closed = false, recovering = false
  private var memoryObserver: NSObjectProtocol?
  private var invalidationHandlers: [UUID: () -> Void] = [:]
  private(set) var maximumThumbnailPixel = 1024
  var peakBytesUsed: Int { imageMemoryBudget.peakBytes }
  var bytesUsed: Int { imageMemoryBudget.bytes }
  init(store: SQLiteStore, studioOriginals: Bool = false) {
    self.store = store
    self.studioOriginals = studioOriginals
    thumbnailRequests.onRemoteActivity = { [weak self] busy in self?.videoPreparation.setPaused(busy) }
    memoryObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.trimMemory() } }
  }
  deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
  /// Файл может ещё отсутствовать, поскольку этот путь также нужен перед загрузкой.
  func fileURL(_ relativePath: String) throws -> URL {
    try Self.fileURL(root: store.root, relative: relativePath)
  }
  /// Не начинает загрузку и не подготавливает изображение, поэтому подходит для быстрого выбора способа
  /// показа.
  func hasLocalOriginal(_ attachment: Attachment) -> Bool {
    guard let file = try? fileURL(attachment.relativePath) else { return false }
    return FileManager.default.fileExists(atPath: file.path)
  }
  nonisolated static func fileURL(root: URL, relative: String) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.hasPrefix("/"), !parts.isEmpty, !parts.contains(""), !parts.contains(".."),
      !parts.contains(".")
    else { throw MediaError.corrupt }
    if let file = cacheFileURL(root: root, parts: parts) { return file }
    let expected = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
      "media")
    var info = stat()
    let status = expected.path.withCString { lstat($0, &info) }
    let base: URL
    if status == 0 {
      // Корень уже приведён к действительному пути, поэтому проверяем сам каталог.
      guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw MediaError.corrupt }
      base = expected
    } else {
      // Для отсутствующего или недоступного каталога сохраняем общую проверку разрешённого пути
      base = expected.resolvingSymlinksInPath().standardizedFileURL
      guard base.path == expected.path else { throw MediaError.corrupt }
    }
    let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else { throw MediaError.corrupt }
    return file
  }
  nonisolated private static func cacheFileURL(root: URL, parts: [Substring]) -> URL? {
    guard root.isFileURL, (root.host ?? "").isEmpty, parts.count == 2,
      parts[0] == "remote" || parts[0] == "previews"
    else { return nil }
    let name = String(parts[1]),
      fields = name.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(fields.count), let stem = fields.first,
      [32, 64].contains(stem.utf8.count),
      stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { return nil }
    if parts[0] == "previews" {
      guard fields.count == 2, fields[1] == "jpg" else { return nil }
    } else if fields.count == 2 {
      guard (1...8).contains(fields[1].utf8.count),
        fields[1].utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) })
      else { return nil }
    }
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    let rootFD = root.path.withCString { Darwin.open($0, flags) }
    guard rootFD >= 0 else { return nil }
    defer { Darwin.close(rootFD) }
    let mediaFD = Darwin.openat(rootFD, "media", flags)
    guard mediaFD >= 0 else { return nil }
    defer { Darwin.close(mediaFD) }
    let directory = String(parts[0]),
      cacheFD = directory.withCString { Darwin.openat(mediaFD, $0, flags) }
    guard cacheFD >= 0 else { return nil }
    defer { Darwin.close(cacheFD) }
    var info = stat()
    let status = name.withCString { Darwin.fstatat(cacheFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
    if status == 0 {
      guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
    } else {
      guard errno == ENOENT else { return nil }
    }
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard bytes.withUnsafeMutableBytes({ Darwin.fcntl(rootFD, F_GETPATH, $0.baseAddress!) }) == 0
    else { return nil }
    let canonical = String(cString: bytes)
    let base = URL(fileURLWithPath: canonical, isDirectory: true).standardizedFileURL
    return base.appendingPathComponent("media", isDirectory: true).appendingPathComponent(
      directory, isDirectory: true
    ).appendingPathComponent(name, isDirectory: false)
  }
  nonisolated static func map(_ error: Error) -> Error {
    if let error = error as? MediaError { return error }
    if let error = error as? RepoError {
      switch error {
      case .storageFull: return MediaError.storageFull
      case .cancelled: return MediaError.cancelled
      case .corrupt: return MediaError.corrupt
      default: return MediaError.io
      }
    }
    let systemError = error as NSError
    if systemError.domain == NSCocoaErrorDomain
      && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(systemError.code)
    {
      return MediaError.permissionDenied
    }
    if (systemError.domain == NSPOSIXErrorDomain && systemError.code == Int(ENOSPC))
      || (systemError.domain == NSCocoaErrorDomain
        && systemError.code == NSFileWriteOutOfSpaceError)
    {
      return MediaError.storageFull
    }
    return MediaError.io
  }
  func stage(sourceURL: URL, mime: String) async throws -> AttachmentDraft {
    try await stage(sourceURL: sourceURL, mime: mime, directory: "objects")
  }
  private func stage(
    sourceURL: URL, mime: String, directory: String, prepareStudioPhoto: Bool = false
  ) async throws -> AttachmentDraft {
    guard !closed, !recovering, sourceURL.isFileURL else { throw MediaError.cancelled }
    let root = store.root, faults = store.faults
    let cancellation = MediaCancellation()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          let request = mediaDecodeQueue.submit(
            work: {
              if prepareStudioPhoto {
                let staging = try Self.ownedDirectory(root: root, name: "staging")
                let prepared = staging.appendingPathComponent(UUID().uuidString + ".studio.jpg")
                defer { try? FileManager.default.removeItem(at: prepared) }
                try Self.prepareStudioPhoto(sourceURL, output: prepared)
                return try Self.copyAndProbe(
                  sourceURL: prepared, root: root, mime: mime, faults: faults, directory: directory)
              }
              return try Self.copyAndProbe(
                sourceURL: sourceURL, root: root, mime: mime, faults: faults, directory: directory)
            },
            dispose: { draft in
              if let url = try? Self.fileURL(root: root, relative: draft.relativePath) {
                try? FileManager.default.removeItem(at: url)
              }
            }, completion: { result in continuation.resume(with: result.mapError { Self.map($0) }) }
          )
          cancellation.onCancel { request.cancel() }
        }
      }, onCancel: { cancellation.cancel() })
  }
  func stageSelection(sourceURL: URL, mime: String) async throws -> AttachmentDraft {
    try await stage(sourceURL: sourceURL, mime: mime, directory: "selections")
  }
  func stageStudioPhoto(sourceURL: URL) async throws -> AttachmentDraft {
    try await stage(
      sourceURL: sourceURL, mime: "image/jpeg", directory: "selections", prepareStudioPhoto: true)
  }
  func discardUnpublishedImport(_ draft: AttachmentDraft) async throws {
    try await discardUnpublishedImports([draft])
  }
  func discardUnpublishedImports(_ drafts: [AttachmentDraft]) async throws {
    for draft in drafts {
      let parts = draft.relativePath.split(separator: "/", omittingEmptySubsequences: false)
      guard UUID(uuidString: draft.id) != nil, parts.count == 2,
        ["objects", "selections"].contains(String(parts[0])),
        URL(fileURLWithPath: draft.relativePath).deletingPathExtension().lastPathComponent
          == draft.id
      else { throw MediaError.corrupt }
    }
    let root = store.root, pending = pendingReferences
    do {
      try await store.perform { db in
        let referencedPaths = try Self.readReferencedPaths(db, pending: pending)
        var files: [URL] = []
        for draft in drafts where !referencedPaths.contains(draft.relativePath) {
          let file: URL
          do { file = try Self.fileURL(root: root, relative: draft.relativePath) } catch {
            throw RepoError.corrupt
          }
          let expected = root.resolvingSymlinksInPath().appendingPathComponent("media")
            .appendingPathComponent(draft.relativePath).standardizedFileURL
          guard file.path == expected.path else { throw RepoError.corrupt }
          files.append(file)
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.removeItem(at: file)
        }
      }
    } catch { throw Self.map(error) }
  }
  /// Файл может ещё не попасть в сообщение, но уже быть нужен черновику или очереди отправки.
  nonisolated private static func readReferencedPaths(
    _ db: SQLiteConnection, pending: ((SQLiteConnection) throws -> Set<String>)?
  ) throws -> Set<String> {
    var referencedPaths = try MediaSelectionStorage.references(db)
    if let pending { referencedPaths.formUnion(try pending(db)) }
    try db.forEachRow("SELECT relativePath FROM attachments", []) { row in
      referencedPaths.insert(row["relativePath"]!.string)
      return true
    }
    try db.forEachRow("SELECT attachmentDraft FROM drafts WHERE attachmentDraft IS NOT NULL", []) {
      row in
      let draft = try JSONDecoder().decode(
        Draft.self, from: Data(row["attachmentDraft"]!.string.utf8))
      for asset in draft.attachmentDrafts + (draft.pendingSend?.attachments ?? [])
        + (draft.pendingMediaBatch ?? []).flatMap(\.attachments)
      { referencedPaths.insert(asset.relativePath) }
      return true
    }
    return referencedPaths
  }
  func recover() async throws {
    guard !closed, !recovering else { throw MediaError.cancelled }
    // Восстановление запускается до обычной работы и не пересекается с действующим импортом или декодированием
    guard mediaDecodeQueue.runningCount == 0, mediaDecodeQueue.pendingCount == 0 else {
      throw MediaError.unavailable
    }
    recovering = true
    defer { recovering = false }
    let pending = self.pendingReferences
    let referencedPaths = try await store.perform { db in
      try Self.readReferencedPaths(db, pending: pending)
    }
    let root = store.root
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      _ = mediaDecodeQueue.submit(
        work: { try Self.deleteUnreferencedFiles(root: root, referencedPaths: referencedPaths) },
        dispose: { _ in },
        completion: { result in
          continuation.resume(with: result.mapError { Self.map($0) })
        })
    }
  }

  nonisolated private static func deleteUnreferencedFiles(root: URL, referencedPaths: Set<String>) throws {
    let fileManager = FileManager.default
    for directoryName in ["staging", "objects", "selections"] {
      let directory = try ownedDirectory(root: root, name: directoryName)
      let files = try fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])
      for file in files {
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let relative = directoryName + "/" + file.lastPathComponent
        if directoryName == "staging" || !referencedPaths.contains(relative) {
          if directoryName != "staging" {
            try VideoCoverDiskCache.revoke(root: root, relativePath: relative)
          }
          try fileManager.removeItem(at: file)
        }
      }
    }
  }

  func isStudioVideo(_ attachment: Attachment) -> Bool {
    studioOriginals && attachment.mime.hasPrefix("video/")
  }
  func wasShownInGallery(_ attachment: Attachment) -> Bool {
    seenGalleryPaths.contains(attachment.relativePath)
  }

  func markShownInGallery(_ attachment: Attachment) {
    let path = attachment.relativePath
    if seenGalleryPaths.last == path { return }
    seenGalleryPaths.removeAll { $0 == path }
    seenGalleryPaths.append(path)
    if seenGalleryPaths.count > 512 { seenGalleryPaths.removeFirst() }
  }

  /// Возвращает отдельный признак оригинала, чтобы этот рисунок не смешивался с обычной уменьшенной копией.
  func studioPhotoKey(_ attachment: Attachment, maxPixel: Int? = nil) -> ThumbnailKey? {
    guard studioOriginals, attachment.relativePath.hasPrefix("remote/"),
      ["image/png", "image/jpeg", "image/webp"].contains(attachment.mime)
    else { return nil }
    let edge = max(attachment.rawWidth, attachment.rawHeight)
    let limit = min(1280, maxPixel ?? 1280)
    return ThumbnailKey(maxPixel: edge > 0 ? min(edge, limit) : limit, studioOriginal: true)
  }
  /// Различает обычный кадр истории и изображение из оригинала, чтобы один вариант не заменял другой в
  /// хранилище готовых пикселей.
  private func thumbnailParameters(_ attachment: Attachment, _ key: ThumbnailKey) -> (
    size: Int, cacheKey: String, original: Bool
  ) {
    let original = key.studioOriginal || key.maxPixel > 1024
    let limit =
      key.studioOriginal
      ? 1280
      : original ? (maximumThumbnailPixel < 1024 ? 1024 : 2048) : maximumThumbnailPixel
    let size = min(limit, key.maxPixel)
    return (
      size,
      attachment.relativePath + (key.gallery ? "@gallery:" : "")
        + (key.studioOriginal ? "@studio:" : original ? "@original:" : "@")
        + String(size), original
    )
  }
  /// Не начинает загрузку и декодирование, поэтому ячейка может сразу показать известный кадр при привязке.
  func cachedThumbnail(attachment: Attachment, key: ThumbnailKey) -> PreparedImage? {
    guard !closed, !recovering else { return nil }
    let parameters = thumbnailParameters(attachment, key)
    guard (1...2048).contains(parameters.size) else { return nil }
    return thumbnailCache.frame(parameters.cacheKey)
  }
  @discardableResult func thumbnail(
    attachment: Attachment, key: ThumbnailKey, ticket: Int, localOnly: Bool = false,
    priority: Int = 1,
    progress: @escaping (Double) -> Void = { _ in },
    localMiss: @escaping () -> Void = {},
    completion: @escaping (Int, Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation {
    if !studioOriginals {
      return loadThumbnail(attachment: attachment, key: key, ticket: ticket, localOnly: localOnly,
        priority: priority, progress: progress, willDownload: { localMiss(); return true },
        completion: completion)
    }
    let identity = thumbnailParameters(attachment, key).cacheKey + (localOnly ? ":local" : ":remote")
    return thumbnailRequests.submit(key: identity, priority: priority, progress: progress,
      localMiss: localMiss,
      start: { priority, willDownload, progress, done in
        self.loadThumbnail(attachment: attachment, key: key, ticket: ticket, localOnly: localOnly,
          priority: priority, progress: progress, willDownload: willDownload) { _, result in done(result) }
      }, completion: { completion(ticket, $0) })
  }
  private func loadThumbnail(
    attachment: Attachment, key: ThumbnailKey, ticket: Int, localOnly: Bool,
    priority: Int, progress: @escaping (Double) -> Void, willDownload: @escaping () -> Bool,
    completion: @escaping (Int, Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation {
    let token = MediaCancellation()
    // Для размера выше обычного кадра истории используется оригинал и отдельное имя готового изображения
    let parameters = thumbnailParameters(attachment, key)
    let size = parameters.size
    let original = parameters.original
    guard !closed, !recovering, (1...2048).contains(size) else {
      DispatchQueue.main.async {
        _ = token.finish()
        completion(ticket, .failure(MediaError.cancelled))
      }
      return token
    }
    let cacheKey = parameters.cacheKey
    if let frame = thumbnailCache.frame(cacheKey) {
      token.onCancel { frame.close() }
      DispatchQueue.main.async {
        if token.finish() {
          completion(ticket, .success(frame))
        } else {
          frame.close()
          completion(ticket, .failure(MediaError.cancelled))
        }
      }
      return token
    }
    let edge = max(attachment.rawWidth, attachment.rawHeight)
    let shortEdge = min(attachment.rawWidth, attachment.rawHeight)
    let height =
      key.studioOriginal && edge > 0 && shortEdge > 0
      ? max(min(size, 512), Int(ceil(Double(size) * Double(shortEdge) / Double(edge)))) : size
    let reserve = size * height * 8 + 4096
    let remote = remoteFile
    let provider = remoteThumbnailProvider
    let gallery = key.gallery ? galleryDisk : nil
    let galleryEpoch = gallery?.epoch()
    let relativePath = attachment.relativePath
    let fetch = MediaCancellation()
    let root = store.root
    fetch.onProgress { value in Task { @MainActor in progress(value) } }
    let request = imageWorkQueue.submit(
      priority: priority, fetch: fetch,
      local: { _ in
        if let file = gallery?.galleryFile(relativePath) { return (file, "image/jpeg") }
        if let provider {
          return try provider.cached(attachment, preview: !original, token: fetch)
        }
        if localOnly || remote == nil || priority <= 0 {
          let url = try Self.fileURL(root: root, relative: attachment.relativePath)
          return FileManager.default.fileExists(atPath: url.path) ? (url, attachment.mime) : nil
        }
        return nil
      },
      remote: { _ in
        guard !localOnly else { throw MediaError.unavailable }
        if let provider { return try provider.resolve(attachment, preview: !original, token: fetch) }
        let url = try Self.fileURL(root: root, relative: attachment.relativePath)
        return try remote?(attachment, !original, fetch) ?? (url, attachment.mime)
      },
      admit: { [weak self] in
        guard let self, !self.closed, !fetch.isCancelled else { throw MediaError.cancelled }
        guard self.thumbnailCache.makeRoom(reserve) || self.tinyPreviewCache.makeRoom(reserve)
          || self.videoPlayback.makeRoom(reserve),
          let charge = self.imageMemoryBudget.reserve(reserve)
        else { throw MediaError.unavailable }
        return charge
      },
      decode: { resolved, charge in
        do {
          if fetch.isCancelled { throw MediaError.cancelled }
          let normal =
            resolved.1.hasPrefix("video/")
            ? try MediaPreviewGenerator.normalFile(
              root: root, relative: attachment.relativePath, file: resolved.0, mime: resolved.1)
            : resolved.0
          if fetch.isCancelled { throw MediaError.cancelled }
          do {
            let image = try Self.decode(
              url: normal, mime: resolved.1.hasPrefix("video/") ? "image/jpeg" : resolved.1,
              maxPixel: size)
            if let gallery, let galleryEpoch {
              guard gallery.epoch() == galleryEpoch, !fetch.isCancelled else {
                throw MediaError.cancelled
              }
              let hasTransparency = [.first, .last, .premultipliedFirst, .premultipliedLast]
                .contains(image.alphaInfo)
              // Копия нужна при возврате, если исходник ушёл из обычного кэша.
              if resolved.0.lastPathComponent.hasSuffix("-gallery.jpg") == false,
                (!hasTransparency || attachment.mime.hasPrefix("video/") || attachment.mime == "image/jpeg"),
                let bytes = try? MediaPreviewGenerator.jpeg(image, quality: 0.78)
              {
                try? gallery.storeGalleryFile(bytes, relative: relativePath, epoch: galleryEpoch)
              }
            }
            try charge.shrink(to: image.bytesPerRow * image.height)
            return ImagePixels(image: image, charge: charge)
          } catch {
            charge.close()
            throw error
          }
        } catch {
          throw Self.map(error)
        }
      },
      willDownload: willDownload,
      completion: { [weak self] result in
        fetch.cancel()
        guard let self, !self.closed else {
          if case .success(let pixels) = result { pixels.closeOwner() }
          completion(ticket, .failure(MediaError.cancelled))
          return
        }
        switch result {
        case .success(let pixels):
          guard token.finish() else {
            pixels.closeOwner()
            completion(ticket, .failure(MediaError.cancelled))
            return
          }
          self.thumbnailCache.insert(pixels, key: cacheKey)
          if let frame = self.thumbnailCache.frame(cacheKey) {
            completion(ticket, .success(frame))
          } else {
            completion(ticket, .failure(MediaError.cancelled))
          }
        case .failure(let error):
          _ = token.finish()
          completion(ticket, .failure(Self.map(error)))
        }
      })
    token.onCancel {
      fetch.cancel()
      request.cancel()
    }
    return token
  }

  private func tinyPreviewKey(_ attachment: Attachment) -> String? {
    guard let text = MediaPreviewStorage.tiny(attachment.tinyPreview) else { return nil }
    return attachment.relativePath + "@tiny:" + text
  }
  /// Возвращает уже подготовленное размытие в ту же привязку, без ожидания очереди.
  func cachedTinyPreview(_ attachment: Attachment) -> PreparedImage? {
    guard studioOriginals, !closed, let key = tinyPreviewKey(attachment) else { return nil }
    return tinyPreviewCache.frame(key)
  }
  /// Не ждёт загрузки оригинала, поэтому даёт первый рисунок до появления более подробного изображения.
  @discardableResult func tinyPreview(
    _ attachment: Attachment, completion: @escaping (Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation {
    if let frame = cachedTinyPreview(attachment) {
      let token = MediaCancellation()
      token.onCancel { frame.close() }
      DispatchQueue.main.async {
        if token.finish() { completion(.success(frame)) }
        else { frame.close(); completion(.failure(MediaError.cancelled)) }
      }
      return token
    }
    guard !closed, let key = tinyPreviewKey(attachment),
      let text = MediaPreviewStorage.tiny(attachment.tinyPreview),
      let data = Data(base64Encoded: text),
      tinyPreviewCache.makeRoom(64 * 64 * 8 + 4096)
        || thumbnailCache.makeRoom(64 * 64 * 8 + 4096)
        || videoPlayback.makeRoom(64 * 64 * 8 + 4096),
      let charge = imageMemoryBudget.reserve(64 * 64 * 8 + 4096)
    else {
      let token = MediaCancellation()
      DispatchQueue.main.async {
        _ = token.finish()
        completion(.failure(MediaError.unavailable))
      }
      return token
    }
    let root = store.root
    return tinyPreviewQueue.submit(
      work: {
        do {
          let image = try TinyPreviewDiskCache.image(
            data, root: root, video: attachment.mime.hasPrefix("video/"))
          try charge.shrink(to: image.bytesPerRow * image.height)
          return ImagePixels(image: image, charge: charge, isTinyPreview: true)
        } catch {
          charge.close()
          throw error
        }
      }, dispose: { $0.closeOwner() },
      completion: { result in
        switch result {
        case let .success(pixels):
          guard !self.closed else {
            pixels.closeOwner()
            completion(.failure(MediaError.cancelled))
            return
          }
          let frame: PreparedImage?
          if self.studioOriginals {
            self.tinyPreviewCache.insert(pixels, key: key)
            frame = self.tinyPreviewCache.frame(key)
          } else {
            frame = pixels.frame()
            pixels.closeOwner()
          }
          if let frame {
            completion(.success(frame))
          } else {
            completion(.failure(MediaError.cancelled))
          }
        case let .failure(error):
          charge.close()
          completion(.failure(error))
        }
      })
  }
  func silentVideoAsset(_ source: MediaPlaybackSource) async throws -> AVAsset {
    let token = MediaCancellation()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          let request = mediaDecodeQueue.submit(
            priority: 1,
            work: {
              guard !token.isCancelled, let video = source.asset.tracks(withMediaType: .video).first
              else { throw MediaError.cancelled }
              let range = video.timeRange
              guard range.duration.seconds.isFinite, range.duration.seconds > 0 else {
                throw MediaError.corrupt
              }
              let asset = AVMutableComposition()
              guard
                let track = asset.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
              else { throw MediaError.unavailable }
              try track.insertTimeRange(range, of: video, at: .zero)
              track.preferredTransform = video.preferredTransform
              return asset as AVAsset
            }, dispose: { _ in }, completion: { continuation.resume(with: $0) })
          token.onCancel {
            source.close()
            request.cancel()
          }
        }
      }, onCancel: { token.cancel() })
  }
  func playbackSource(
    _ attachment: Attachment, localOnly: Bool = false
  ) async throws -> MediaPlaybackSource {
    if localOnly {
      let provider = remoteThumbnailProvider, token = MediaCancellation(), root = store.root
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          let request = mediaDecodeQueue.submit(
            work: {
              let file: URL?
              if let provider {
                file = try provider.cached(attachment, preview: false, token: token)?.0
              } else {
                let url = try Self.fileURL(root: root, relative: attachment.relativePath)
                file = FileManager.default.fileExists(atPath: url.path) ? url : nil
              }
              guard !token.isCancelled, let file else {
                token.cancel()
                throw MediaError.unavailable
              }
              return MediaPlaybackSource(file: file, onClose: { token.cancel() })
            }, dispose: { $0.close() }, completion: { continuation.resume(with: $0) })
          token.onCancel { request.cancel() }
        }
      } onCancel: {
        token.cancel()
      }
    }
    guard let remote = remotePlayback else {
      return MediaPlaybackSource(file: try await ensureOriginal(attachment))
    }
    let token = MediaCancellation(), root = store.root
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          let request = mediaDecodeQueue.submit(
            work: {
              guard !token.isCancelled else { throw MediaError.cancelled }
              _ = try Self.fileURL(root: root, relative: attachment.relativePath)
              return try remote(attachment, token)
            }, dispose: { $0.close() }, completion: { continuation.resume(with: $0) })
          token.onCancel { request.cancel() }
        }
      }, onCancel: { token.cancel() })
  }
  func prepareStudioVideo(_ attachment: Attachment) -> MediaCancellation? {
    guard studioOriginals, !closed, !recovering, attachment.relativePath.hasPrefix("remote/"),
      attachment.mime == "video/mp4", attachment.byteSize > 0,
      attachment.byteSize <= 64 * 1024 * 1024,
      let playback = remotePlayback
    else { return nil }
    return videoPreparation.acquire(attachment.relativePath) { fetch in
      let source = try playback(attachment, fetch)
      defer { source.close() }
      fetch.onCancel { source.close() }
      guard !fetch.isCancelled else { throw MediaError.cancelled }
      try source.prepareForPlayback(fetch)
    }
  }
  /// Отмена прекращает ожидающее чтение, а готовые изображения соседних сообщений не очищаются из-за
  /// завершения этого запроса.
  func ensureOriginal(_ attachment: Attachment, progress: @escaping (Double) -> Void = { _ in })
    async throws -> URL
  {
    let remote = remoteFile, fetch = MediaCancellation(), root = store.root
    fetch.onProgress { value in Task { @MainActor in progress(value) } }
    let resolved: URL = try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<URL, Error>) in
          let request = mediaDecodeQueue.submit(
            work: {
              guard !fetch.isCancelled else { throw MediaError.cancelled }
              let url = try Self.fileURL(root: root, relative: attachment.relativePath)
              return try remote?(attachment, false, fetch).0 ?? url
            }, dispose: { _ in }, completion: { continuation.resume(with: $0) })
          fetch.onCancel { request.cancel() }
        }
      }, onCancel: { fetch.cancel() })
    return resolved
  }
  private var navigating = false
  func withNavigationCache<T>(_ action: () throws -> T) rethrows -> T {
    let previous = navigating
    navigating = true
    defer {
      navigating = previous
      thumbnailCache.retainNavigationImages()
    }
    return try action()
  }
  func releaseIdleImages() {
    if navigating { thumbnailCache.retainNavigationImages() }
    else {
      thumbnailCache.clear()
      tinyPreviewCache.clear()
      videoPlayback.clearFrames()
    }
  }
  /// Используется поверхностями и проигрывателями, чтобы они вовремя завершили работу с прежними ресурсами.
  func registerInvalidation(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    invalidationHandlers[id] = action
    return id
  }
  func unregisterInvalidation(_ id: UUID) { invalidationHandlers.removeValue(forKey: id) }
  func trimMemory() {
    maximumThumbnailPixel = 512
    videoPreparation.clear()
    for invalidate in Array(invalidationHandlers.values) { invalidate() }
    thumbnailCache.clear()
    tinyPreviewCache.clear()
    videoPlayback.clearFrames()
    imageMemoryBudget.limit = 24 * 1024 * 1024
  }
  func close() {
    guard !closed else { return }
    closed = true
    videoPlayback.close()
    galleryDisk.close()
    seenGalleryPaths.removeAll()
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    memoryObserver = nil
    for invalidate in Array(invalidationHandlers.values) { invalidate() }
    invalidationHandlers.removeAll()
    mediaDecodeQueue.close()
    thumbnailRequests.clear()
    imageWorkQueue.close()
    tinyPreviewQueue.close()
    videoPreparation.close()
    thumbnailCache.clear()
    tinyPreviewCache.clear()
  }
  nonisolated private static func ownedDirectory(root: URL, name: String) throws -> URL {
    let base = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("media")
    let dir = base.appendingPathComponent(name)
    guard base.resolvingSymlinksInPath().path == base.path,
      dir.resolvingSymlinksInPath().path == dir.path
    else { throw MediaError.corrupt }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
  nonisolated private static func syncDirectory(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { throw MediaError.io }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw errno == ENOSPC ? MediaError.storageFull : MediaError.io }
  }
  nonisolated private static func prepareStudioPhoto(_ sourceURL: URL, output: URL) throws {
    let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...64 * 1024 * 1024).contains(size),
      let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw MediaError.unavailable }
    let index = CGImageSourceGetPrimaryImageIndex(source)
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...32768).contains(width), (1...32768).contains(height),
      Int64(width) * Int64(height) <= 64_000_000
    else { throw MediaError.unavailable }
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options),
      max(image.width, image.height) <= 2048
    else { throw MediaError.corrupt }
    try StudioPhotoEncoder().jpeg(image, to: output)
  }
  nonisolated private static func copyAndProbe(
    sourceURL: URL, root: URL, mime: String, faults: RepositoryFaults, directory: String
  ) throws -> AttachmentDraft {
    let fileExtensions = [
      "image/jpeg": "jpg", "image/png": "png", "image/heic": "heic", "image/heif": "heif",
      "image/gif": "gif", "video/mp4": "mp4", "video/quicktime": "mov", "audio/mp4": "m4a"
    ]
    guard let fileExtension = fileExtensions[mime] else { throw MediaError.unavailable }
    let fileManager = FileManager.default
    let id = UUID().uuidString.lowercased()
    let stagingDirectory = try ownedDirectory(root: root, name: "staging")
    let destinationDirectory = try ownedDirectory(root: root, name: directory)
    let temporaryFile = stagingDirectory.appendingPathComponent(id + ".part." + fileExtension)
    let destinationFile = destinationDirectory.appendingPathComponent(id + "." + fileExtension)
    defer { try? fileManager.removeItem(at: temporaryFile) }
    let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }
    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }
    guard !fileManager.fileExists(atPath: destinationFile.path) else { throw MediaError.io }
    let fileDescriptor = Darwin.open(temporaryFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fileDescriptor >= 0 else { throw MediaError.io }
    let output = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    var byteCount: Int64 = 0
    do {
      while let data = try input.read(upToCount: 65536), !data.isEmpty {
        byteCount += Int64(data.count)
        guard byteCount <= 64 * 1024 * 1024 else { throw MediaError.unavailable }
        #if DEBUG
          if faults.consume(.storageFull) {
            try output.write(contentsOf: data.prefix(16))
            throw POSIXError(.ENOSPC)
          }
        #endif
        try output.write(contentsOf: data)
      }
      try output.synchronize()
      try output.close()
    } catch {
      try? output.close()
      throw error
    }
    var draft = try probe(
      url: temporaryFile, mime: mime, id: id, relative: directory + "/" + destinationFile.lastPathComponent,
      bytes: byteCount)
    if faults.consume(.beforeRename) { throw MediaError.io }
    guard Darwin.rename(temporaryFile.path, destinationFile.path) == 0 else {
      throw errno == ENOSPC ? MediaError.storageFull : MediaError.io
    }
    try syncDirectory(destinationDirectory)
    if faults.consume(.afterRename) { throw MediaError.io }
    draft.thumbnailKey = id
    if mime.hasPrefix("image/") || mime.hasPrefix("video/") {
      if let previewFile = try? MediaPreviewGenerator.normalFile(
        root: root, relative: draft.relativePath, file: destinationFile, mime: mime)
      {
        draft.tinyPreview = try? MediaPreviewGenerator.tiny(normal: previewFile)
      }
    }
    return draft
  }
  nonisolated private static func probe(
    url: URL, mime: String, id: String, relative: String, bytes: Int64
  ) throws -> AttachmentDraft {
    var result = AttachmentDraft(id: id, relativePath: relative, mime: mime, byteSize: bytes)
    if mime.hasPrefix("image/") {
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let imageProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
          as? [CFString: Any],
        let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? NSNumber,
        let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? NSNumber
      else { throw MediaError.corrupt }
      result.rawWidth = pixelWidth.intValue
      result.rawHeight = pixelHeight.intValue
      result.orientation =
        (imageProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      if result.orientation == 0 { result.orientation = 1 }
      guard result.rawWidth > 0, result.rawHeight > 0, result.rawWidth <= 32768,
        result.rawHeight <= 32768,
        Int64(result.rawWidth) * Int64(result.rawHeight) <= 64_000_000,
        (1...8).contains(result.orientation)
      else { throw MediaError.unavailable }
      if mime == "image/png", Int64(result.rawWidth) * Int64(result.rawHeight) > 16_000_000 {
        throw MediaError.unavailable
      }
    } else {
      let asset = AVURLAsset(url: url)
      let seconds = asset.duration.seconds
      guard seconds.isFinite, seconds > 0, seconds <= 86400 else { throw MediaError.corrupt }
      result.durationMs = Int64((seconds * 1000).rounded())
      if mime.hasPrefix("video/") {
        guard let track = asset.tracks(withMediaType: .video).first else {
          throw MediaError.corrupt
        }
        result.rawWidth = Int(abs(track.naturalSize.width))
        result.rawHeight = Int(abs(track.naturalSize.height))
        let angle = Int(
          (atan2(track.preferredTransform.b, track.preferredTransform.a) * 180 / Double.pi)
            .rounded())
        result.orientation = angle == 90 ? 6 : angle == -90 ? 8 : abs(angle) == 180 ? 3 : 1
      } else if asset.tracks(withMediaType: .audio).isEmpty {
        throw MediaError.corrupt
      }
    }
    return result
  }
  nonisolated private static func decode(url: URL, mime: String, maxPixel: Int) throws -> CGImage {
    let image: CGImage
    if mime.hasPrefix("video/") {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
      image = try generator.copyCGImage(at: .zero, actualTime: nil)
    } else {
      guard
        let source = CGImageSourceCreateWithURL(
          url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let value = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary)
      else { throw MediaError.corrupt }
      image = value
    }
    guard max(image.width, image.height) <= maxPixel,
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw MediaError.corrupt }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = context.makeImage() else { throw MediaError.corrupt }
    return result
  }
}
