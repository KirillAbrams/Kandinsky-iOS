import XCTest
import Foundation
import CryptoKit
@testable import Kandinsky

private final class DownloadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func completed() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
private final class CacheScanFileManager: FileManager, @unchecked Sendable {
  private let gate = NSLock()
  private var scans = 0
  var enumerations: Int {
    gate.lock()
    defer { gate.unlock() }
    return scans
  }
  override func contentsOfDirectory(
    at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    gate.lock()
    scans += 1
    gate.unlock()
    return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
  }
}
@MainActor final class NetworkDiskCacheTests: XCTestCase {
  private struct CacheRecord: Decodable {
    let blobID: String, sha256: String
    let byteSize: Int
  }
  private struct CacheWorkingSet: Decodable {
    let chatId: Int, previews: [CacheRecord], pressureOriginals: [CacheRecord]
  }
  private func workingSet() throws -> CacheWorkingSet {
    let root = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let value = try JSONDecoder().decode(
      CacheWorkingSet.self,
      from: Data(contentsOf: root.appendingPathComponent("real-media/cache-working-set.json")))
    XCTAssertEqual(value.chatId, 1352)
    XCTAssertEqual(value.previews.count, 2800)
    XCTAssertEqual(Set(value.previews.map(\.blobID)).count, 2800)
    XCTAssertEqual(Set(value.previews.map(\.sha256)).count, 2800)
    XCTAssertEqual(value.previews.reduce(0) { $0 + $1.byteSize }, 77_301_963)
    return value
  }
  private func defaultBudget(_ remote: NetworkMedia, preview: Bool) throws -> NetworkDiskBudget {
    let fields = Mirror(reflecting: remote).children
    // Читает настроенный рабочий ограничитель, включая прежний общий вариант
    let field =
      preview
      ? (fields.first { $0.label == "previewDiskBudget" }
        ?? fields.first { $0.label == "diskBudget" }) : fields.first { $0.label == "diskBudget" }
    return try XCTUnwrap(field?.value as? NetworkDiskBudget)
  }
  private func replay(
    _ records: [CacheRecord], root: URL, directory: String, budget: NetworkDiskBudget, epoch: Int
  ) throws -> Int {
    var misses = 0
    for (index, record) in records.enumerated() {
      let file = root.appendingPathComponent("media/" + directory + "/" + record.blobID + ".cache")
      let missing = !FileManager.default.fileExists(atPath: file.path)
      if missing {
        misses += 1
        _ = try sparse(
          root, directory + "/" + file.lastPathComponent, record.byteSize, Double(epoch + index))
      } else {
        try FileManager.default.setAttributes(
          [.modificationDate: Date(timeIntervalSince1970: Double(epoch + index))],
          ofItemAtPath: file.path)
      }
      try budget.accept(keep: file, addedBytes: missing ? record.byteSize : 0) {
        try FileManager.default.removeItem(at: $0)
        return true
      }
    }
    return misses
  }
  /// Второй проход не должен терять файлы из-за недостаточного объёма области подложек.
  func testPublishedPreviewWorkingSetSurvivesASecondDiskPass() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let fixture = try workingSet(), api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api),
      budget = try defaultBudget(remote, preview: true)
    let cold = try replay(
      fixture.previews, root: h.root, directory: "previews", budget: budget, epoch: 100)
    let repeated = try replay(
      fixture.previews, root: h.root, directory: "previews", budget: budget, epoch: 10_000)
    print(
      "KANDINSKY_DISK_REPLAY previews=\(fixture.previews.count) coldMisses=\(cold) repeatedMisses=\(repeated)"
    )
    XCTAssertEqual(cold, 2800)
    XCTAssertEqual(
      repeated, 0,
      "Published previews must survive a complete repeated pass without original downloads")
    try await h.close()
  }
  func testOriginalDiskPressureDoesNotEvictPublishedPreviews() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let fixture = try workingSet(), api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api),
      previews = Array(fixture.previews.prefix(1000))
    XCTAssertLessThan(previews.reduce(0) { $0 + $1.byteSize }, 40 * 1024 * 1024)
    XCTAssertGreaterThan(fixture.pressureOriginals.reduce(0) { $0 + $1.byteSize }, 80 * 1024 * 1024)
    let small = try defaultBudget(remote, preview: true),
      original = try defaultBudget(remote, preview: false)
    _ = try replay(previews, root: h.root, directory: "previews", budget: small, epoch: 100)
    _ = try replay(
      fixture.pressureOriginals, root: h.root, directory: "remote", budget: original, epoch: 10_000)
    let retained = previews.filter {
      FileManager.default.fileExists(
        atPath: h.root.appendingPathComponent("media/previews/" + $0.blobID + ".cache").path)
    }.count
    let files = try FileManager.default.contentsOfDirectory(
      at: h.root.appendingPathComponent("media/remote"), includingPropertiesForKeys: [.fileSizeKey])
    let originalBytes = try files.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    print(
      """
      KANDINSKY_DISK_DOMAINS previews=\(previews.count) retainedAfterOriginalPressure=\(retained) \
      originalBytes=\(originalBytes)
      """
    )
    XCTAssertEqual(
      retained, previews.count, "Large originals must not evict the lightweight preview domain")
    XCTAssertLessThanOrEqual(originalBytes, 64 * 1024 * 1024)
    XCTAssertLessThan(
      files.count, fixture.pressureOriginals.count, "Original cleanup must still run")
    try await h.close()
  }
  /// Очистка подложек не должна удалить оригинал другой области.
  func testDefaultPreviewOverflowTrimsOnlyItsOwnDirectory() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api)
    let original = try sparse(h.root, "remote/original.cache", 8 * 1024 * 1024, 1)
    for i in 0..<16 {
      _ = try sparse(h.root, "previews/expired-\(i).cache", 6 * 1024 * 1024, Double(i + 2))
    }
    let record = try XCTUnwrap(workingSet().previews.first)
    let keep = try sparse(h.root, "previews/" + record.blobID + ".cache", record.byteSize, 100)
    try defaultBudget(remote, preview: true).accept(keep: keep) {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: keep.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    XCTAssertLessThanOrEqual(bytes, 88 * 1024 * 1024)
    XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: original.path),
      "Preview pressure must not touch the original domain")
    try await h.close()
  }
  func testCachedPreviewServicesPendingOriginalPromotionCleanup() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let (a, preview, bytes) = try gateFixture(h, preview: true), fixture = try workingSet(),
      counter = DownloadCounter()
    let api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api),
      original = try defaultBudget(remote, preview: false)
    try original.accept(keep: preview) {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    for record in fixture.pressureOriginals {
      _ = try sparse(h.root, "remote/" + record.blobID + ".cache", record.byteSize)
      original.recordWrite(bytes: record.byteSize)
    }
    let request = MediaCancellation()
    let resolved = try await Task.detached { try remote.resolve(a, preview: true, token: request) }
      .value
    let files = try FileManager.default.contentsOfDirectory(
      at: h.root.appendingPathComponent("media/remote"), includingPropertiesForKeys: [.fileSizeKey])
    let remaining = try files.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    print(
      """
      KANDINSKY_PENDING_ORIGINAL_CLEANUP before=\(fixture.pressureOriginals.reduce(0){$0+$1.byteSize}) \
      after=\(remaining)
      """
    )
    XCTAssertLessThanOrEqual(
      remaining, 56 * 1024 * 1024,
      "A preview read must still service pending original cleanup after range promotion")
    XCTAssertEqual(resolved.0, preview)
    XCTAssertEqual(try Data(contentsOf: preview), bytes)
    XCTAssertEqual(counter.value, 0)
    request.cancel()
    try await h.close()
  }
  private func whileDownloadGateIsHeld<T: Sendable>(
    _ remote: NetworkMedia, body: @escaping @Sendable () throws -> T
  ) async throws -> (Result<T, Error>, Double) {
    let gate = try XCTUnwrap(
      Mirror(reflecting: remote).children.first { $0.label == "downloads" }?.value as? NSLock)
    let entered = expectation(description: "Unrelated download owns its serialization gate"),
      finished = expectation(description: "Gate owner released on the same native thread")
    let release = DispatchSemaphore(value: 0), released = DownloadCounter()
    DispatchQueue(label: "Kandinsky.test.held-download").async {
      gate.lock()
      entered.fulfill()
      _ = release.wait(timeout: .now() + 3)
      released.completed()
      gate.unlock()
      finished.fulfill()
    }
    defer { release.signal() }
    await fulfillment(of: [entered], timeout: 2)
    let observed = await Task.detached {
      let genuinelyHeld = released.value == 0, begin = ProcessInfo.processInfo.systemUptime
      let result = Result { try body() }
      return (
        result, ProcessInfo.processInfo.systemUptime - begin, genuinelyHeld && released.value == 0
      )
    }.value
    release.signal()
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertTrue(
      observed.2, "The cached read must finish while an unrelated download still holds its lock")
    return (observed.0, observed.1)
  }
  private func gateFixture(_ h: RepositoryHarness, preview: Bool) throws -> (Attachment, URL, Data)
  {
    let folder = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media")
    let source = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: folder.appendingPathComponent("cached-preview-source.json")))
        as? [String: Any])
    let original = try XCTUnwrap(source["originalBlobId"] as? String),
      small = try XCTUnwrap(source["previewBlobId"] as? String)
    let data = try Data(
      contentsOf: folder.appendingPathComponent(try XCTUnwrap(source["fileName"] as? String)))
    XCTAssertEqual(
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      source["previewSHA256"] as? String)
    // В проверке оригинала этот подлинный файл используется как самостоятельный исходник
    let blob = preview ? original : small,
      path = NetworkMedia.relativePath(blob: blob, mime: "image/jpeg")
    var attachment = Attachment(
      id: "gate-cache", relativePath: path, mime: "image/jpeg",
      byteSize: preview ? 1967774 : Int64(data.count), rawWidth: 512, rawHeight: 300,
      orientation: 1, durationMs: nil, thumbnailKey: blob)
    attachment.remoteLocation = RemoteMediaLocation(
      blobID: blob, previewBlobID: preview ? small : nil, mime: attachment.mime,
      byteSize: attachment.byteSize)
    let file = h.root.appendingPathComponent(
      "media/" + (preview ? "previews/" + small + ".jpg" : path))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    return (attachment, file, data)
  }
  func testRealCachedPreviewDoesNotWaitForAnUnrelatedDownloadGate() async throws {
    try await assertCachedFileBypassesDownloadGate(preview: true)
  }

  func testRealCachedOriginalDoesNotWaitForAnUnrelatedDownloadGate() async throws {
    try await assertCachedFileBypassesDownloadGate(preview: false)
  }

  private func assertCachedFileBypassesDownloadGate(preview: Bool) async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let (a, file, data) = try gateFixture(h, preview: preview), count = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { count.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api)
    let (result, seconds) = try await whileDownloadGateIsHeld(remote) {
      try remote.resolve(a, preview: preview, token: MediaCancellation())
    }
    let value = try result.get()
    XCTAssertEqual(value.0, file)
    XCTAssertEqual(value.1, "image/jpeg")
    XCTAssertEqual(try Data(contentsOf: value.0), data)
    XCTAssertEqual(count.value, 0)
    let kind = preview ? "preview" : "original"
    print("KANDINSKY_CACHE_GATE \(kind)Seconds=\(seconds)")
    try await h.close()
  }

  func testPreCancelledResolveDoesNotWaitForAnUnrelatedDownloadGate() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let (a, _, _) = try gateFixture(h, preview: true), count = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { count.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api), token = MediaCancellation()
    token.cancel()
    let (result, seconds) = try await whileDownloadGateIsHeld(remote) {
      try remote.resolve(a, preview: true, token: token)
    }
    switch result {
    case .success: XCTFail("Pre-cancelled work must fail")
    case let .failure(error): XCTAssertEqual(error as? MediaError, .cancelled)
    }
    XCTAssertEqual(count.value, 0)
    print("KANDINSKY_CACHE_GATE cancelledSeconds=\(seconds)")
    try await h.close()
  }
  /// Пока запрос открыт, его файл должен пережить очистку других записей.
  func testCachedReadRemainsPinnedUntilTokenFinishCancelOrDeallocation() async throws {
    for end in ["finish", "cancel", "deallocate"] {
      let h = try await RepositoryHarness.open(), fm = FileManager.default
      defer { try? fm.removeItem(at: h.root) }
      let (a, file, data) = try gateFixture(h, preview: true), counter = DownloadCounter(),
        api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
      api.close()
      let remote = NetworkMedia(
        store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root))
      var playing: [MediaPlaybackSource] = []
      defer { playing.forEach { $0.close() } }
      for i in 0..<8 {
        let blob = String(format: "%032x", i + 1),
          url = try sparse(h.root, "remote/" + blob + ".mp4", 8 * 1024 * 1024)
        let asset = Attachment(
          id: blob, relativePath: "remote/" + url.lastPathComponent, mime: "video/mp4",
          byteSize: 8 * 1024 * 1024, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 1000,
          thumbnailKey: blob)
        playing.append(
          try await Task.detached { try remote.playback(asset, token: MediaCancellation()) }.value)
      }
      var token: MediaCancellation? = MediaCancellation()
      weak var weakToken = token
      func read(_ asset: Attachment, _ request: MediaCancellation) async throws -> (URL, String) {
        try await Task.detached { try remote.resolve(asset, preview: true, token: request) }.value
      }
      let first = try await read(a, try XCTUnwrap(token))
      XCTAssertEqual(first.0, file)
      let otherID = String(repeating: "c", count: 32),
        otherFile = h.root.appendingPathComponent("media/previews/" + otherID + ".jpg")
      try data.write(to: otherFile)
      var other = a
      other.remoteLocation = RemoteMediaLocation(
        blobID: try XCTUnwrap(a.remoteLocation).blobID, previewBlobID: otherID, mime: a.mime,
        byteSize: a.byteSize)
      let otherToken = MediaCancellation()
      _ = try await read(other, otherToken)
      let protected = fm.fileExists(atPath: file.path)
      XCTAssertTrue(
        protected,
        "An admitted cached source must survive another preview's quota cleanup while its request still owns it: \(end)"
      )
      if protected { XCTAssertEqual(try Data(contentsOf: file), data) }
      switch end {
      case "finish": XCTAssertTrue(try XCTUnwrap(token).finish())
      case "cancel": token?.cancel()
      default:
        token = nil
        XCTAssertNil(weakToken, "The ownership closure must not retain its cancellation token")
      }
      _ = try await read(other, otherToken)
      XCTAssertFalse(
        fm.fileExists(atPath: file.path),
        "Ending the request must release its pin so bounded disk eviction can retry: \(end)")
      XCTAssertEqual(try Data(contentsOf: otherFile), data)
      XCTAssertEqual(counter.value, 0)
      print(
        """
        KANDINSKY_CACHE_READ_LEASE end=\(end) protectedWhileActive=\(protected) \
        evictableAfterEnd=\(!fm.fileExists(atPath:file.path))
        """
      )
      otherToken.cancel()
      playing.forEach { $0.close() }
      try await h.close()
    }
  }
  func testCachedPreviewReturnsWhileSQLiteWorkerIsBusy() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media")
    let source = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("cached-preview-source.json")))
        as? [String: Any])
    let blob = try XCTUnwrap(source["originalBlobId"] as? String),
      preview = try XCTUnwrap(source["previewBlobId"] as? String)
    let name = try XCTUnwrap(source["fileName"] as? String),
      expected = try Data(contentsOf: fixtures.appendingPathComponent(name))
    XCTAssertEqual(
      SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
      source["previewSHA256"] as? String)
    let
      delta = try await h.repo.send(
        SendCommand(operationID: UUID().uuidString, chatID: 2, text: "Фото из настоящего чата")),
      id = try XCTUnwrap(delta.inserted.first?.id)
    let path = NetworkMedia.relativePath(blob: blob, mime: "image/jpeg")
    try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute("UPDATE messages SET kind='photo' WHERE id=?", [.integer(id)])
      try db.execute(
        """
        INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height,\
        durationMs,thumbnailKey,orientation) \
        VALUES('cached-page',?,?,'image/jpeg',1967774,3000,1732,NULL,?,1)
        """,
        [.integer(id), .text(path), .text(blob)])
      try db.execute(
        """
        INSERT INTO net_media(attachmentID,blobID,previewBlobID,mime,byteSize) \
        VALUES('cached-page',?,?,'image/jpeg',1967774)
        """,
        [.text(blob), .text(preview)])
    }
    let repo = NetworkChatRepository(
      local: SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: 1009)), wake: {})
    let page = try await repo.history(PageRequest(chatID: 2)),
      attachment = try XCTUnwrap(page.rows.first?.attachments.first)
    let file = h.root.appendingPathComponent("media/previews/" + preview + ".jpg")
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try expected.write(to: file)
    let counter = DownloadCounter(), completed = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api),
      entered = expectation(description: "SQLite worker held after batched page read"),
      release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let held = Task.detached {
      try await h.store.perform { _ in
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw RepoError.io }
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    let request = Task.detached {
      let result = try remote.resolve(attachment, preview: true, token: MediaCancellation())
      completed.completed()
      return result
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    let returnedBeforeDatabaseRelease = completed.value == 1
    release.signal()
    let result = try await request.value
    try await held.value
    XCTAssertTrue(
      returnedBeforeDatabaseRelease,
      "Already cached preview must not wait for another per-photo SQLite mapping task")
    XCTAssertEqual(result.0, file)
    XCTAssertEqual(result.1, "image/jpeg")
    XCTAssertEqual(try Data(contentsOf: file), expected)
    XCTAssertEqual(counter.value, 0)
    try await h.close()
  }
  func testCachedDescriptorPreviewRemainsProtectedWhenOtherFilesArePinned() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    var a = try await warmPreview(h)
    a.remoteLocation = RemoteMediaLocation(
      blobID: String(repeating: "a", count: 32), previewBlobID: String(repeating: "b", count: 32),
      mime: a.mime, byteSize: a.byteSize)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media")
    let source = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("cached-preview-source.json")))
        as? [String: Any])
    let bytes = try Data(
      contentsOf: fixtures.appendingPathComponent(try XCTUnwrap(source["fileName"] as? String)))
    let keep = h.root.appendingPathComponent(
      "media/previews/" + String(repeating: "b", count: 32) + ".jpg")
    try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: keep)
    let api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root))
    var pins: [MediaPlaybackSource] = []
    defer { pins.forEach { $0.close() } }
    for index in 0..<8 {
      let blob = String(format: "%032x", index + 1),
        file = try sparse(h.root, "remote/" + blob + ".mp4", 8 * 1024 * 1024)
      let asset = Attachment(
        id: blob, relativePath: "remote/" + file.lastPathComponent, mime: "video/mp4",
        byteSize: 8 * 1024 * 1024, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 1000,
        thumbnailKey: blob)
      pins.append(
        try await Task.detached { try remote.playback(asset, token: MediaCancellation()) }.value)
    }
    let attachment = a
    _ = try await Task.detached {
      try remote.resolve(attachment, preview: true, token: MediaCancellation())
    }.value
    XCTAssertTrue(
      fm.fileExists(atPath: keep.path),
      "Canonical system aliases must not let eviction delete the preview being returned")
    XCTAssertEqual(try? Data(contentsOf: keep), bytes)
    pins.forEach { $0.close() }
    try await h.close()
  }
  func testLegacyAttachmentJSONAndLocationRoundtrip() throws {
    let blob = String(repeating: "a", count: 32)
    let old = """
      {"id":"old-photo","relativePath":"remote/\(blob).jpg","mime":"image/jpeg","byteSize":1024,\
      "rawWidth":64,"rawHeight":64,"orientation":1,"thumbnailKey":"\(blob)"}
      """
    var a = try JSONDecoder().decode(Attachment.self, from: Data(old.utf8))
    XCTAssertNil(a.remoteLocation, "Existing stored attachment JSON must remain readable")
    a.remoteLocation = RemoteMediaLocation(
      blobID: blob, previewBlobID: String(repeating: "b", count: 64), mime: a.mime,
      byteSize: a.byteSize)
    XCTAssertTrue(
      try XCTUnwrap(a.remoteLocation).isValid,
      "Both32and64character immutable blob IDs are supported")
    XCTAssertEqual(try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(a)), a)
  }
  func testInvalidSnapshotLocationUsesAuthoritativeFallbackAndHonoursCancel() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    var a = try await warmPreview(h)
    let file = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1024)
    a.remoteLocation = RemoteMediaLocation(
      blobID: String(repeating: "a", count: 32), previewBlobID: "../outside", mime: a.mime,
      byteSize: a.byteSize)
    let counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api), invalid = a
    let result = try await Task.detached {
      try remote.resolve(invalid, preview: true, token: MediaCancellation())
    }.value
    XCTAssertEqual(result.0, file)
    XCTAssertEqual(counter.value, 0)
    let token = MediaCancellation()
    token.cancel()
    do {
      _ = try await Task.detached { try remote.resolve(invalid, preview: true, token: token) }.value
      XCTFail("Pre-cancelled cached work must fail")
    } catch { XCTAssertEqual(error as? MediaError, .cancelled) }
    a.remoteLocation = RemoteMediaLocation(
      blobID: String(repeating: "c", count: 32), previewBlobID: String(repeating: "d", count: 32),
      mime: a.mime, byteSize: a.byteSize)
    let mismatched = a
    let fallback = try await Task.detached {
      try remote.resolve(mismatched, preview: true, token: MediaCancellation())
    }.value
    XCTAssertEqual(
      fallback.0, file, "A stale original ID cannot redirect the attachment to another cached image"
    )
    try await h.close()
  }
  func testSnapshotPreviewCannotReadAnOutsideFileAlias() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    var a = try await warmPreview(h)
    a.remoteLocation = RemoteMediaLocation(
      blobID: String(repeating: "a", count: 32), previewBlobID: String(repeating: "b", count: 32),
      mime: a.mime, byteSize: a.byteSize)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/cached-preview-b2cf77e3cafb4ba5ad916d15533f3298.jpg")
    let before = try Data(contentsOf: fixture),
      alias = h.root.appendingPathComponent(
        "media/previews/" + String(repeating: "b", count: 32) + ".jpg")
    try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: fixture)
    let scans = CacheScanFileManager(), counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let
      remote = NetworkMedia(
        store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: scans)),
      attachment = a
    do {
      _ = try await Task.detached {
        try remote.resolve(attachment, preview: true, token: MediaCancellation())
      }.value
      XCTFail("Preview alias escaped the owned media root")
    } catch { XCTAssertEqual(error as? MediaError, .corrupt) }
    XCTAssertEqual(scans.enumerations, 0)
    XCTAssertEqual(counter.value, 0)
    XCTAssertEqual(try Data(contentsOf: fixture), before)
    try await h.close()
  }
  /// Контрольный внешний исходник не должен измениться.
  func testDirectResolverRejectsCachedOriginalOutsideFileAlias() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    let a = try await warmPreview(h)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/cached-preview-b2cf77e3cafb4ba5ad916d15533f3298.jpg")
    let before = try Data(contentsOf: fixture),
      alias = h.root.appendingPathComponent("media/" + a.relativePath)
    try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: fixture)
    let counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api)
    do {
      _ = try await Task.detached {
        try remote.resolve(a, preview: false, token: MediaCancellation())
      }.value
      XCTFail(
        "The provider must reject an original outside its owned media root before returning it")
    } catch { XCTAssertEqual(error as? MediaError, .corrupt) }
    XCTAssertEqual(counter.value, 0)
    XCTAssertEqual(try Data(contentsOf: fixture), before)
    try await h.close()
  }
  func testDirectResolverRejectsOutsideLegacyAliasBeforeRenaming() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    let a = try await warmPreview(h)
    let attachment = Attachment(
      id: a.id, relativePath: "remote/" + String(repeating: "a", count: 32), mime: a.mime,
      byteSize: a.byteSize, rawWidth: a.rawWidth, rawHeight: a.rawHeight,
      orientation: a.orientation, durationMs: a.durationMs, thumbnailKey: a.thumbnailKey)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/cached-preview-b2cf77e3cafb4ba5ad916d15533f3298.jpg")
    let before = try Data(contentsOf: fixture),
      alias = h.root.appendingPathComponent("media/" + attachment.relativePath),
      typed = alias.appendingPathExtension("jpg")
    try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: alias, withDestinationURL: fixture)
    let counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(store: h.store, api: api)
    do {
      _ = try await Task.detached {
        try remote.resolve(attachment, preview: true, token: MediaCancellation())
      }.value
      XCTFail("An escaping legacy alias must be rejected before migration")
    } catch { XCTAssertEqual(error as? MediaError, .corrupt) }
    XCTAssertTrue(fm.fileExists(atPath: alias.path))
    XCTAssertFalse(fm.fileExists(atPath: typed.path))
    XCTAssertEqual(counter.value, 0)
    XCTAssertEqual(try Data(contentsOf: fixture), before)
    try await h.close()
  }
  func testSelectedProviderDecodesRealCachedPreviewAndReleasesIt() async throws {
    let h = try await RepositoryHarness.open(), fm = FileManager.default
    defer { try? fm.removeItem(at: h.root) }
    let blob = "824d66cce0d64409ad4888a13792c7d4", preview = "b2cf77e3cafb4ba5ad916d15533f3298"
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/cached-preview-" + preview + ".jpg")
    let bytes = try Data(contentsOf: fixture),
      file = h.root.appendingPathComponent("media/previews/" + preview + ".jpg")
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file)
    var a = Attachment(
      id: "real-selected-preview",
      relativePath: NetworkMedia.relativePath(blob: blob, mime: "image/jpeg"), mime: "image/jpeg",
      byteSize: 1967774, rawWidth: 3000, rawHeight: 1732, orientation: 1, durationMs: nil,
      thumbnailKey: blob)
    a.remoteLocation = RemoteMediaLocation(
      blobID: blob, previewBlobID: preview, mime: a.mime, byteSize: a.byteSize)
    let counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let media = MediaStore(store: h.store)
    media.remoteThumbnailProvider = NetworkMedia(store: h.store, api: api)
    media.remoteFile = { _, _, _ in
      XCTFail("An authoritative selected-file provider must not re-enter the raw adapter")
      throw MediaError.corrupt
    }
    let
      done = expectation(
        description: "Real cached512pxpreview decoded through the production provider"),
      attachment = a
    var result: PreparedImage?
    _ = media.thumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: 512), ticket: 71) {
      ticket, outcome in
      XCTAssertEqual(ticket, 71)
      switch outcome {
      case let .success(frame): result = frame
      case let .failure(error): XCTFail("Cached preview failed: \(error)")
      }
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(result?.image?.width, 512)
    XCTAssertEqual(result?.image?.height, 296)
    XCTAssertEqual(counter.value, 0)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    result?.close()
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  private func sparse(_ root: URL, _ relative: String, _ size: Int, _ age: TimeInterval = 100)
    throws -> URL
  {
    let file = root.appendingPathComponent("media/" + relative)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: age)], ofItemAtPath: file.path)
    return file
  }
  private func cachedBytes(_ root: URL) throws -> Int {
    try ["remote", "previews"].flatMap { name in
      try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("media/" + name), includingPropertiesForKeys: nil)
    }.reduce(0) { total, file in
      total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
  }
  private func warmPreview(_ h: RepositoryHarness) async throws -> Attachment {
    let blob = String(repeating: "a", count: 32), preview = String(repeating: "b", count: 32)
    try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT INTO net_media(attachmentID,blobID,previewBlobID,mime,byteSize) VALUES(?,?,?,?,?)",
        [.text("warm-cache"), .text(blob), .text(preview), .text("image/jpeg"), .integer(1024)])
    }
    return Attachment(
      id: "warm-cache", relativePath: NetworkMedia.relativePath(blob: blob, mime: "image/jpeg"),
      mime: "image/jpeg", byteSize: 1024, rawWidth: 64, rawHeight: 64, orientation: 1,
      durationMs: nil, thumbnailKey: "")
  }
  func testWarmPreviewDoesNotEnumerateTheCacheAgain() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let a = try await warmPreview(h),
      file = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1024)
    let fm = CacheScanFileManager(), counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    let remote = NetworkMedia(
      store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: fm))
    for _ in 0..<100 {
      let value = try await Task.detached {
        try remote.resolve(a, preview: true, token: MediaCancellation())
      }.value
      XCTAssertEqual(value.0, file)
    }
    XCTAssertEqual(counter.value, 0, "Warm disk reads must not create HTTP requests")
    XCTAssertEqual(fm.enumerations, 2, "A warm read must not rescan every original and preview")
    XCTAssertEqual(try Data(contentsOf: file).count, 1024)
    let modified = try XCTUnwrap(
      file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    XCTAssertGreaterThan(modified, Date(timeIntervalSince1970: 100))
    try await h.close()
  }
  func testEvictionLeavesHeadroomAndPreservesPinnedOriginal() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let a = try await warmPreview(h),
      keep = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1234)
    let pinned = try sparse(
      h.root, "remote/" + String(repeating: "c", count: 32) + ".mp4", 8 * 1024 * 1024)
    for index in 0..<7 {
      _ = try sparse(h.root, "previews/old-\(index).jpg", 8 * 1024 * 1024, Double(101 + index))
    }
    let local = try sparse(h.root, "catalog/owned-original.bin", 1024)
    let api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root))
    let video = Attachment(
      id: "pinned", relativePath: "remote/" + pinned.lastPathComponent, mime: "video/mp4",
      byteSize: 8 * 1024 * 1024, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 1000,
      thumbnailKey: "")
    let source = try await Task.detached { try remote.playback(video, token: MediaCancellation()) }
      .value
    _ = try await Task.detached { try remote.resolve(a, preview: true, token: MediaCancellation()) }
      .value
    XCTAssertLessThanOrEqual(
      try cachedBytes(h.root), 56 * 1024 * 1024,
      "Evict a batch so every new preview does not trigger a directory scan")
    XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    source.close()
    try await h.close()
  }
  func testSmallAdmissionsDoNotRepeatDirectoryAudit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = CacheScanFileManager(), budget = NetworkDiskBudget(root: root, fileManager: fm),
      keep = try sparse(root, "remote/base.mp4", 100)
    let remove: (URL) throws -> Bool = {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    try budget.accept(keep: keep, remove: remove)
    for index in 0..<16 {
      let file = try sparse(root, "previews/small-\(index).jpg", 1024)
      try budget.accept(keep: file, addedBytes: 1024, remove: remove)
    }
    XCTAssertEqual(
      fm.enumerations, 2, "Known small writes below the quota must use size accounting")
    XCTAssertEqual(try cachedBytes(root), 100 + 16 * 1024)
  }
  func testKnownGrowthCrossingQuotaTriggersAnAccurateAudit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = CacheScanFileManager(), budget = NetworkDiskBudget(root: root, fileManager: fm)
    var keep = try sparse(root, "remote/first.mp4", 8 * 1024 * 1024)
    for index in 0..<7 {
      keep = try sparse(root, "previews/old-\(index).jpg", 8 * 1024 * 1024, Double(index + 101))
    }
    let remove: (URL) throws -> Bool = {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    try budget.accept(keep: keep, remove: remove)
    XCTAssertEqual(try cachedBytes(root), 64 * 1024 * 1024)
    let newest = try sparse(root, "previews/new.jpg", 1024)
    try budget.accept(keep: newest, addedBytes: 1024, remove: remove)
    XCTAssertLessThanOrEqual(try cachedBytes(root), 56 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
  }
  /// Отказ поиска не меняет файлы и не должен сбрасывать уже выполненную сверку объёма.
  func testFailedLookupDoesNotForgetAnUnchangedWarmCache() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let a = try await warmPreview(h)
    _ = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1024)
    let fm = CacheScanFileManager(), api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(
      store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: fm))
    _ = try await Task.detached { try remote.resolve(a, preview: true, token: MediaCancellation()) }
      .value
    let missing = Attachment(
      id: "no-such-catalog-entry",
      relativePath: "remote/" + String(repeating: "d", count: 32) + ".jpg", mime: "image/jpeg",
      byteSize: 1024, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: nil, thumbnailKey: ""
    )
    do {
      _ = try await Task.detached {
        try remote.resolve(missing, preview: true, token: MediaCancellation())
      }.value
      XCTFail("An unknown catalog entry must fail")
    } catch {
      if case RepoError.notFound = error {} else { XCTFail("Unexpected lookup failure: \(error)") }
    }
    _ = try await Task.detached { try remote.resolve(a, preview: true, token: MediaCancellation()) }
      .value
    XCTAssertEqual(
      fm.enumerations, 2, "A failed lookup changed no files and must not force a directory audit")
    try await h.close()
  }
  func testKnownPromotionsKeepAccurateSizeWithoutRepeatedAudits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = CacheScanFileManager(), budget = NetworkDiskBudget(root: root, fileManager: fm),
      keep = try sparse(root, "previews/marker.jpg", 1024)
    let remove: (URL) throws -> Bool = {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    try budget.accept(keep: keep, remove: remove)
    for index in 0..<16 {
      let file = try sparse(root, "remote/promoted-\(index).mp4", 1024)
      budget.recordWrite(bytes: 1024)
      try budget.accept(keep: file, remove: remove)
    }
    XCTAssertEqual(
      fm.enumerations, 2, "The exact size of a verified promotion needs accounting, not enumeration"
    )
    let final = try sparse(root, "remote/large-promoted.mp4", 64 * 1024 * 1024)
    budget.recordWrite(bytes: 64 * 1024 * 1024)
    try budget.accept(keep: keep, remove: remove)
    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    XCTAssertLessThanOrEqual(try cachedBytes(root), 64 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 4, "Crossing the quota must still force an accurate audit")
  }
  func testPinnedOverflowRemainsUsableAndRetriesAfterRelease() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try sparse(root, "remote/first.mp4", 40 * 1024 * 1024),
      keep = try sparse(root, "previews/keep.jpg", 40 * 1024 * 1024)
    let budget = NetworkDiskBudget(root: root)
    var pinned = true
    let remove: (URL) throws -> Bool = { file in
      if pinned { return false }
      try FileManager.default.removeItem(at: file)
      return true
    }
    try budget.accept(keep: keep, remove: remove)
    XCTAssertEqual(try cachedBytes(root), 80 * 1024 * 1024)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    pinned = false
    try budget.accept(keep: keep, remove: remove)
    XCTAssertEqual(try cachedBytes(root), 40 * 1024 * 1024)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
  }
  func testRemovalFailureRequiresANewAuditBeforeTrustingTheTotal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = CacheScanFileManager(), budget = NetworkDiskBudget(root: root, fileManager: fm)
    let keep = try sparse(root, "remote/keep.mp4", 8 * 1024 * 1024)
    for index in 0..<8 { _ = try sparse(root, "previews/old-\(index).jpg", 8 * 1024 * 1024) }
    XCTAssertThrowsError(try budget.accept(keep: keep) { _ in throw MediaError.io })
    try budget.accept(keep: keep) {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    XCTAssertLessThanOrEqual(try cachedBytes(root), 56 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
  }
  func testPreCancelledResolveDoesNotScanOrStartHTTP() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let a = try await warmPreview(h), fm = CacheScanFileManager(), counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    defer { api.close() }
    let
      remote = NetworkMedia(
        store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: fm)),
      token = MediaCancellation()
    token.cancel()
    do {
      _ = try await Task.detached { try remote.resolve(a, preview: true, token: token) }.value
      XCTFail("Pre-cancelled media must not be admitted")
    } catch let error as MediaError { XCTAssertEqual(error, .cancelled) }
    XCTAssertEqual(fm.enumerations, 0)
    XCTAssertEqual(counter.value, 0)
    try await h.close()
  }
  /// Одновременно запускает много чтений одного готового файла.
  func testConcurrentWarmResolvesShareOneDirectoryAudit() async throws {
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let a = try await warmPreview(h),
      file = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1024)
    let fm = CacheScanFileManager(), api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(
      store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: fm))
    try await withThrowingTaskGroup(of: URL.self) { group in
      for _ in 0..<20 {
        group.addTask { try remote.resolve(a, preview: true, token: MediaCancellation()).0 }
      }
      for try await url in group { XCTAssertEqual(url, file) }
    }
    XCTAssertEqual(fm.enumerations, 2)
    try await h.close()
  }
  func testVerifiedRangePromotionInvalidatesBudgetExactlyOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = CacheScanFileManager(), budget = NetworkDiskBudget(root: root, fileManager: fm),
      marker = try sparse(root, "previews/marker.jpg", 1)
    let remove: (URL) throws -> Bool = {
      try FileManager.default.removeItem(at: $0)
      return true
    }
    try budget.accept(keep: marker, remove: remove)
    _ = try sparse(root, "remote/older.mp4", 64 * 1024 * 1024)
    let bytes = Data((0..<128).map { UInt8($0) }),
      blob = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      original = root.appendingPathComponent("media/remote/" + blob + ".mp4"),
      promotions = DownloadCounter()
    let range = try MediaRangeCache(
      root: root, blob: blob, length: Int64(bytes.count), original: original,
      onPromoted: {
        promotions.completed()
        budget.invalidate()
      }
    ) { start, end, _ in bytes.subdata(in: Int(start)..<Int(end + 1)) }
    XCTAssertEqual(try range.read(offset: 0, count: 128, cancellation: MediaCancellation()), bytes)
    try budget.accept(keep: original, remove: remove)
    XCTAssertLessThanOrEqual(try cachedBytes(root), 64 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 4)
    XCTAssertEqual(promotions.value, 1)
    XCTAssertEqual(
      try range.read(offset: 10, count: 10, cancellation: MediaCancellation()),
      bytes.subdata(in: 10..<20))
    try budget.accept(keep: original, remove: remove)
    XCTAssertEqual(fm.enumerations, 4)
    XCTAssertEqual(promotions.value, 1)
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    range.close()
  }
  func testCorruptRangeNeverAnnouncesAPromotedOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let promotions = DownloadCounter(),
      original = root.appendingPathComponent("media/remote/invalid.mp4")
    let range = try MediaRangeCache(
      root: root, blob: String(repeating: "a", count: 64), length: 128, original: original,
      onPromoted: { promotions.completed() }
    ) { _, _, _ in Data(repeating: 0, count: 128) }
    XCTAssertThrowsError(try range.read(offset: 0, count: 128, cancellation: MediaCancellation()))
    XCTAssertEqual(promotions.value, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    range.close()
  }
  func testActualDownloadedBytesCannotBypassAnAlreadyAuditedQuota() async throws {
    let profile = try StudioTestServer.profile()
    let lookup = NetworkAPI(profile: profile)
    defer { lookup.close() }
    let data = try await StudioTestServer.recentMedia(lookup).1,
      json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]),
      rows = try XCTUnwrap(json["messages"] as? [[String: Any]])
    let photo = try XCTUnwrap(rows.first { $0["kind"] as? String == "photo" }),
      wire = try XCTUnwrap((photo["attachments"] as? [[String: Any]])?.first)
    let blob = try XCTUnwrap(wire["blobId"] as? String),
      mime = try XCTUnwrap(wire["mime"] as? String),
      size = try XCTUnwrap(wire["byteSize"] as? NSNumber).int64Value
    let h = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: h.root) }
    let warm = try await warmPreview(h)
    _ = try sparse(h.root, "previews/" + String(repeating: "b", count: 32) + ".jpg", 1024)
    for index in 0..<7 { _ = try sparse(h.root, "remote/filler-\(index).mp4", 8 * 1024 * 1024) }
    _ = try sparse(h.root, "remote/filler-last.mp4", 8 * 1024 * 1024 - 1024)
    try await h.store.perform { db in
      try db.execute(
        "INSERT INTO net_media(attachmentID,blobID,previewBlobID,mime,byteSize) VALUES(?,?,NULL,?,?)",
        [.text("live-cache-growth"), .text(blob), .text(mime), .integer(size)])
    }
    let a = Attachment(
      id: "live-cache-growth", relativePath: NetworkMedia.relativePath(blob: blob, mime: mime),
      mime: mime, byteSize: size, rawWidth: 512, rawHeight: 512, orientation: 1, durationMs: nil,
      thumbnailKey: "")
    let fm = CacheScanFileManager(), counter = DownloadCounter(),
      api = NetworkAPI(profile: profile, onRequestFinished: { counter.completed() })
    defer { api.close() }
    let remote = NetworkMedia(
      store: h.store, api: api, diskBudget: NetworkDiskBudget(root: h.root, fileManager: fm))
    _ = try await Task.detached {
      try remote.resolve(warm, preview: true, token: MediaCancellation())
    }.value
    XCTAssertEqual(try cachedBytes(h.root), 64 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 2)
    let result = try await Task.detached {
      try remote.resolve(a, preview: false, token: MediaCancellation())
    }.value
    XCTAssertEqual(try result.0.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
    XCTAssertLessThanOrEqual(try cachedBytes(h.root), 56 * 1024 * 1024)
    XCTAssertEqual(fm.enumerations, 4)
    for _ in 0..<100 {
      if counter.value > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(counter.value, 1, "Only the new original needs HTTP; the warm preview is local")
    try await h.close()
  }
  func testStudioRemovalEvictsOriginalPosterAndRangesWithoutTouchingAnotherBlob() async throws {
    let h = try await RepositoryHarness.open()
    let api = NetworkAPI(profile: nil), remote = NetworkMedia(store: h.store, api: api)
    defer { api.close() }
    let blob = String(repeating: "a", count: 32), preview = String(repeating: "b", count: 32),
      other = String(repeating: "c", count: 32)
    let removal = try XCTUnwrap(StudioMediaRemoval(blob: blob, preview: preview))
    let relative = "remote/" + blob + ".mp4"
    let paths = [
      relative, "previews/" + preview + ".jpg",
      "previews/" + MediaPreviewGenerator.derivedName(relative), "ranges/" + blob + "/0.chunk"
    ]
    for path in paths { _ = try sparse(h.root, path, 16, 1) }
    let retained = try sparse(h.root, "remote/" + other + ".mp4", 16, 1)
    try await Task.detached {
      try remote.removeCached(removal)
      try remote.removeCached(removal)
    }.value
    for path in paths {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: h.root.appendingPathComponent("media/" + path).path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    let a = Attachment(
      id: "retired", relativePath: relative, mime: "video/mp4", byteSize: 16, rawWidth: 32,
      rawHeight: 20, orientation: 1, durationMs: 1000, thumbnailKey: blob)
    do {
      _ = try await Task.detached {
        try remote.resolve(a, preview: false, token: MediaCancellation())
      }.value
      XCTFail("A retired result must not restart a transfer")
    } catch { XCTAssertEqual(error as? MediaError, .cancelled) }
    try await h.close()
  }
  func testDiskHitWorksWithoutNetworkAndRefreshesLastUse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("cached.jpg"),
      bytes = Data("authored persistent cache bytes".utf8), old = Date(timeIntervalSince1970: 100)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    let counter = DownloadCounter(),
      api = NetworkAPI(profile: nil, onRequestFinished: { counter.completed() })
    api.close()
    try await api.download(blob: String(repeating: "a", count: 32), to: file, limit: 1024)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertEqual(counter.value, 0)
    let used = try XCTUnwrap(
      file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    XCTAssertGreaterThan(used, old, "A disk cache hit must refresh eviction recency")
  }
  func testConcurrentRemoteOpensDownloadOnceAndKeepFileAfterRamClear() async throws {
    let profile = try StudioTestServer.profile()
    let lookup = NetworkAPI(profile: profile)
    defer { lookup.close() }
    let data = try await StudioTestServer.recentMedia(lookup).1
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try XCTUnwrap(json["messages"] as? [[String: Any]])
    let photo = try XCTUnwrap(rows.first { $0["kind"] as? String == "photo" })
    let wire = try XCTUnwrap((photo["attachments"] as? [[String: Any]])?.first)
    let blob = try XCTUnwrap(wire["blobId"] as? String),
      mime = try XCTUnwrap(wire["mime"] as? String),
      size = try XCTUnwrap(wire["byteSize"] as? NSNumber).int64Value
    let h = try await RepositoryHarness.open(), counter = DownloadCounter()
    try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT INTO net_media(attachmentID,blobID,previewBlobID,mime,byteSize) VALUES(?,?,NULL,?,?)",
        [.text("cache-probe"), .text(blob), .text(mime), .integer(size)])
    }
    let a = Attachment(
      id: "cache-probe", relativePath: NetworkMedia.relativePath(blob: blob, mime: mime),
      mime: mime, byteSize: size, rawWidth: (wire["rawWidth"] as? NSNumber)?.intValue ?? 512,
      rawHeight: (wire["rawHeight"] as? NSNumber)?.intValue ?? 512, orientation: 1, durationMs: nil,
      thumbnailKey: "")
    let api = NetworkAPI(profile: profile, onRequestFinished: { counter.completed() }),
      remote = NetworkMedia(store: h.store, api: api)
    defer { api.close() }
    let first = Task.detached { try remote.resolve(a, preview: false, token: MediaCancellation()) }
    let second = Task.detached { try remote.resolve(a, preview: false, token: MediaCancellation()) }
    let one = try await first.value, two = try await second.value
    XCTAssertEqual(one.0, two.0)
    XCTAssertEqual(try Data(contentsOf: one.0).count, Int(size))
    for _ in 0..<100 {
      if counter.value > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(
      counter.value, 1, "Concurrent requests for one blob must share the on-disk result")
    let media = MediaStore(store: h.store)
    media.remoteFile = { try remote.resolve($0, preview: $1, token: $2) }
    let frame: PreparedImage = try await withCheckedThrowingContinuation { c in
      _ = media.thumbnail(attachment: a, key: ThumbnailKey(maxPixel: 512), ticket: 0) { _, result in
        c.resume(with: result)
      }
    }
    XCTAssertNotNil(frame.image)
    frame.close()
    media.releaseIdleImages()
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: one.0.path))
    let before = counter.value
    let reopened = try await Task.detached {
      try remote.resolve(a, preview: false, token: MediaCancellation())
    }.value
    XCTAssertEqual(reopened.0, one.0)
    XCTAssertEqual(counter.value, before)
    try await h.close()
  }
  func testLiveAuthenticatedRangeAndMissingSessionRejection() async throws {
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile), anonymous = NetworkAPI(profile: nil)
    defer {
      api.close()
      anonymous.close()
    }
    let data = try await StudioTestServer.recentMedia(api).1,
      json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]),
      rows = try XCTUnwrap(json["messages"] as? [[String: Any]])
    let
      video = try XCTUnwrap(
        rows.first { $0["kind"] as? String == "video" || $0["kind"] as? String == "round" }),
      wire = try XCTUnwrap((video["attachments"] as? [[String: Any]])?.first),
      blob = try XCTUnwrap(wire["blobId"] as? String),
      size = try XCTUnwrap(wire["byteSize"] as? NSNumber).int64Value
    let bytes = try await Task.detached {
      try api.range(blob: blob, start: 0, end: 4095, length: size, token: MediaCancellation())
    }.value
    XCTAssertEqual(bytes.count, 4096)
    XCTAssertEqual(String(data: bytes.subdata(in: 4..<8), encoding: .ascii), "ftyp")
    do {
      _ = try await Task.detached {
        try anonymous.range(
          blob: blob, start: 0, end: 4095, length: size, token: MediaCancellation())
      }.value
      XCTFail("An unprovisioned reader must not receive media bytes")
    } catch let failure as NetworkFailure { XCTAssertEqual(failure.status, 401) }
  }

}
