import XCTest
import AVFoundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Kandinsky
private func mediaTestImage(_ width: Int, _ height: Int) -> CGImage {
  let c = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
  c.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return c.makeImage()!
}
private final class NativeDecodeProbe {
  var image: CGImage?
  private(set) var closeCount = 0
  init() { image = mediaTestImage(32, 20) }
  func close() {
    if closeCount == 0 {
      closeCount = 1
      image = nil
    }
  }
}
@MainActor final class MediaStoreTests: XCTestCase {
  func testLeavingStudioOutsideNavigationReleasesCachedBlurPixels() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let asset = Attachment(id: draft.id, relativePath: draft.relativePath, mime: draft.mime,
      byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
      orientation: draft.orientation, durationMs: draft.durationMs,
      thumbnailKey: draft.thumbnailKey, tinyPreview: draft.tinyPreview)
    let frame: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      media.tinyPreview(asset) { continuation.resume(with: $0) }
    }
    frame.close()
    XCTAssertGreaterThan(media.bytesUsed, 0)
    media.releaseIdleImages()
    XCTAssertEqual(media.bytesUsed, 0, "Leaving the app must release cached blurred pixels too")
    XCTAssertNil(media.cachedTinyPreview(asset))
    media.close(); try await h.close()
  }

  func testVideoPreparationChangesNearestRowWithoutDroppingPreparedPosters() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let photo = source(), root = h.store.root
    let pixelLimit = MediaImagePrefetch.albumMaxPixel
    let a = Attachment(id: "near-a", relativePath: "remote/" + String(repeating: "a", count: 32) + ".mp4",
      mime: "video/mp4", byteSize: 1024, rawWidth: 640, rawHeight: 480, orientation: 1,
      durationMs: 1000, thumbnailKey: "near-a")
    let b = Attachment(id: "near-b", relativePath: "remote/" + String(repeating: "b", count: 32) + ".mp4",
      mime: "video/mp4", byteSize: 1024, rawWidth: 640, rawHeight: 480, orientation: 1,
      durationMs: 1000, thumbnailKey: "near-b")
    media.remoteFile = { _, _, _ in (photo, "image/jpeg") }
    for attachment in [a, b] {
      let frame: PreparedImage = try await withCheckedThrowingContinuation { continuation in
        media.thumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: pixelLimit), ticket: 0) {
          _, result in continuation.resume(with: result)
        }
      }
      frame.close()
    }
    let entered = expectation(description: "first video ranges started")
    let changed = expectation(description: "new nearest video started")
    let release = DispatchSemaphore(value: 0)
    media.remotePlayback = { attachment, _ in
      let first = attachment.id == a.id
      if !first { changed.fulfill() }
      let cache = try MediaRangeCache(root: root, blob: String(repeating: first ? "a" : "b", count: 32),
        length: 1024, original: root.appendingPathComponent("media/" + attachment.relativePath)) {
        _, _, token in
        if first {
          entered.fulfill()
          token.onCancel { release.signal() }
          _ = release.wait(timeout: .now() + 3)
          throw MediaError.cancelled
        }
        return Data(repeating: 7, count: 1024)
      }
      return MediaPlaybackSource(cache: cache, mime: attachment.mime, blob: attachment.id)
    }
    let prefetch = MediaImagePrefetch()
    defer { release.signal(); prefetch.clear(); media.close() }
    prefetch.update([a, b].map { .init(attachment: $0, maxPixel: pixelLimit) }, store: media)
    await fulfillment(of: [entered], timeout: 1)
    prefetch.update([b, a].map { .init(attachment: $0, maxPixel: pixelLimit) }, store: media)
    await fulfillment(of: [changed], timeout: 1)
    for attachment in [a, b] {
      let frame = prefetch.preview(.init(attachment: attachment, maxPixel: pixelLimit), store: media)
      XCTAssertNotNil(frame)
      if let pixels = frame?.image { XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), pixelLimit) }
      frame?.close()
      XCTAssertNil(prefetch.preview(.init(attachment: attachment), store: media),
        "The album-size poster must not start a second single-tile representation")
    }
    prefetch.clear(); media.close(); try await h.close()
  }

  func testVideoPreparationWarmsBoundedStartAndTailForTheNextPlayer() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let byteCount = 2 * 1024 * 1024 + 17
    let data = Data((0..<byteCount).map { UInt8($0 % 251) })
    let blob = String(repeating: "a", count: 32)
    let asset = Attachment(id: "range-warm", relativePath: "remote/" + blob + ".mp4",
      mime: "video/mp4", byteSize: Int64(data.count), rawWidth: 640, rawHeight: 480,
      orientation: 1, durationMs: 8000, thumbnailKey: blob)
    let warmed = expectation(description: "beginning and tail are prepared")
    var fetched: [(Int64, Int64)] = []
    let gate = NSLock(), root = h.store.root
    func source() throws -> MediaPlaybackSource {
      let cache = try MediaRangeCache(root: root, blob: blob, length: Int64(data.count),
        original: root.appendingPathComponent("media/" + asset.relativePath)) { start, end, _ in
        gate.lock(); fetched.append((start, end)); let count = fetched.count; gate.unlock()
        if count == 3 { warmed.fulfill() }
        return data.subdata(in: Int(start)..<Int(end + 1))
      }
      return MediaPlaybackSource(cache: cache, mime: asset.mime, blob: blob)
    }
    media.remotePlayback = { _, _ in try source() }
    let token = media.prepareStudioVideo(asset)
    defer { token?.cancel(); media.close() }
    XCTAssertNotNil(token, "Video preparation must use the ranged playback provider")
    await fulfillment(of: [warmed], timeout: 2)
    gate.lock(); let requests = fetched; gate.unlock()
    XCTAssertEqual(requests.map { Int($0.0) / MediaRangeCache.chunkSize }, [0, 1, 8])
    XCTAssertLessThanOrEqual(requests.reduce(Int64(0)) { $0 + $1.1 - $1.0 + 1 }, 3 * 256 * 1024)
    try await Task.sleep(for: .milliseconds(50))
    let cache = try MediaRangeCache(root: root, blob: blob, length: Int64(data.count),
      original: root.appendingPathComponent("media/" + asset.relativePath)) { _, _, _ in
      XCTFail("The next player must reuse prepared parts"); throw MediaError.io
    }
    XCTAssertEqual(try cache.read(offset: 0, count: 10, cancellation: MediaCancellation()), data.prefix(10))
    XCTAssertEqual(try cache.read(offset: Int64(data.count - 10), count: 10,
      cancellation: MediaCancellation()), data.suffix(10))
    cache.close(); media.close()
    try await h.close()
  }

  func testForegroundPhotoPreemptsOtherPrefetchAndSamePhotoJoinsOneRequest() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let original = source(), started = expectation(description: "background transfer started")
    let stopped = expectation(description: "background transfer cancelled for foreground")
    let foreground = expectation(description: "foreground pixels do not wait for background")
    let release = DispatchSemaphore(value: 0)
    let a = Attachment(id: "a", relativePath: "remote/prefetch-a.jpg", mime: "image/jpeg", byteSize: 1,
      rawWidth: 640, rawHeight: 480, orientation: 1, durationMs: nil, thumbnailKey: "a")
    let b = Attachment(id: "b", relativePath: "remote/visible-b.jpg", mime: "image/jpeg", byteSize: 1,
      rawWidth: 640, rawHeight: 480, orientation: 1, durationMs: nil, thumbnailKey: "b")
    var didStart = false, didStop = false
    var cancelledAt: TimeInterval?, visibleAt: TimeInterval?
    let gate = NSLock()
    media.remoteFile = { attachment, _, token in
      if attachment.id == "a" {
        gate.lock(); let first = !didStart; didStart = true; gate.unlock()
        if first { started.fulfill() }
        token.onCancel {
          gate.lock(); let first = !didStop; didStop = true
          if first { cancelledAt = Date.timeIntervalSinceReferenceDate }
          gate.unlock()
          if first { stopped.fulfill() }
          release.signal()
        }
        guard release.wait(timeout: .now() + 4) == .success, !token.isCancelled else {
          throw MediaError.cancelled
        }
      } else {
        gate.lock(); visibleAt = Date.timeIntervalSinceReferenceDate; gate.unlock()
      }
      return (original, "image/jpeg")
    }
    let background = media.thumbnail(attachment: a, key: ThumbnailKey(maxPixel: 512), ticket: 0,
      priority: 0) { _, result in if case let .success(frame) = result { frame.close() } }
    defer { background.cancel(); release.signal(); media.close() }
    await fulfillment(of: [started], timeout: 1)
    _ = media.thumbnail(attachment: b, key: ThumbnailKey(maxPixel: 512), ticket: 0) { _, result in
      if case let .success(frame) = result { frame.close(); foreground.fulfill() }
    }
    await fulfillment(of: [stopped, foreground], timeout: 1)
    let delay = try XCTUnwrap(visibleAt) - XCTUnwrap(cancelledAt)
    print("KANDINSKY_PREFETCH_FOREGROUND_ADMISSION milliseconds=\(delay * 1000)")
    XCTAssertGreaterThanOrEqual(delay, 0)
    XCTAssertLessThan(delay, 0.15)
    background.cancel()
    media.close()
    try await h.close()
  }

  func testVisiblePhotoJoinsPrefetchWithoutAnotherDownloadOrDecode() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let value = Attachment(id: "shared", relativePath: "remote/shared.jpg", mime: "image/jpeg", byteSize: 1,
      rawWidth: 640, rawHeight: 480, orientation: 1, durationMs: nil, thumbnailKey: "shared")
    let original = source(), started = expectation(description: "prefetch started")
    let release = DispatchSemaphore(value: 0), gate = NSLock()
    var calls = 0
    media.remoteFile = { _, _, token in
      gate.lock(); calls += 1; let count = calls; gate.unlock()
      if count == 1 { started.fulfill() }
      token.onCancel { release.signal() }
      guard release.wait(timeout: .now() + 4) == .success else { throw MediaError.interrupted }
      return (original, "image/jpeg")
    }
    var frames: [PreparedImage] = []
    let done = expectation(description: "both subscribers get pixels"); done.expectedFulfillmentCount = 2
    let callback: (Int, Result<PreparedImage, Error>) -> Void = { _, result in
      if case let .success(frame) = result { frames.append(frame) } else { XCTFail("Lost subscriber") }
      done.fulfill()
    }
    let a = media.thumbnail(attachment: value, key: ThumbnailKey(maxPixel: 512), ticket: 0,
      priority: 0, completion: callback)
    defer { a.cancel(); release.signal(); frames.forEach { $0.close() }; media.close() }
    await fulfillment(of: [started], timeout: 1)
    let b = media.thumbnail(attachment: value, key: ThumbnailKey(maxPixel: 512), ticket: 0, completion: callback)
    defer { b.cancel() }
    release.signal()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(calls, 1, "Visibility must promote existing work")
    XCTAssertEqual(frames.count, 2)
    if frames.count == 2 { XCTAssertTrue(frames[0].image === frames[1].image) }
    frames.forEach { $0.close() }; frames.removeAll()
    media.close()
    try await h.close()
  }
  func testPreparedStudioBlurDoesNotFinishDeliveryBeforeOriginalPixels() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let value = Attachment(
      id: draft.id, relativePath: "remote/studio-blur.jpg", mime: draft.mime,
      byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
      orientation: draft.orientation, durationMs: draft.durationMs,
      thumbnailKey: draft.thumbnailKey, tinyPreview: try XCTUnwrap(draft.tinyPreview))
    let tiny: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      _ = media.tinyPreview(value) { continuation.resume(with: $0) }
    }
    tiny.close()
    let release = DispatchSemaphore(value: 0), original = source()
    media.remoteFile = { _, _, token in
      token.onCancel { release.signal() }
      guard release.wait(timeout: .now() + 5) == .success else { throw MediaError.interrupted }
      return (original, "image/jpeg")
    }
    let slot = MediaImageSlot(store: media)
    defer { release.signal(); slot.close(); media.close() }
    slot.bind(value, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
      kind: .photo, studioPhotoDelivery: true)
    let first = slot.preview()
    XCTAssertNotNil(first, "A completed generated file may show own prepared blur while downloading")
    XCTAssertTrue(slot.awaitingStudioPhoto, "Blurred pixels must not finish original delivery")
    first?.close()
    release.signal()
    let deadline = Date().addingTimeInterval(3)
    while slot.awaitingStudioPhoto, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(slot.awaitingStudioPhoto)
    let full = try XCTUnwrap(slot.preview())
    XCTAssertGreaterThan(try XCTUnwrap(full.image).width, 64)
    full.close()
    slot.close()
    media.close()
    try await h.close()
  }
  func testStudioTinyCacheHas64EntriesAndReleasesOwnersOnWarningAndClose() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let tiny = try XCTUnwrap(draft.tinyPreview)
    var last: Attachment?, one = 0
    for index in 0..<80 {
      let value = Attachment(
        id: "tiny-\(index)", relativePath: "remote/tiny-\(index).jpg", mime: draft.mime,
        byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
        orientation: draft.orientation, durationMs: draft.durationMs,
        thumbnailKey: "tiny-\(index)", tinyPreview: tiny)
      let frame: PreparedImage = try await withCheckedThrowingContinuation { continuation in
        _ = media.tinyPreview(value) { continuation.resume(with: $0) }
      }
      let image = try XCTUnwrap(frame.image)
      one = image.bytesPerRow * image.height
      frame.close()
      XCTAssertLessThanOrEqual(media.bytesUsed, 64 * one)
      last = value
    }
    var changed = try XCTUnwrap(last)
    changed.tinyPreview = "AA=="
    XCTAssertNil(media.cachedTinyPreview(changed), "Changed inline bytes cannot reuse another tiny")
    let held = try XCTUnwrap(media.cachedTinyPreview(try XCTUnwrap(last)))
    media.trimMemory()
    XCTAssertNil(media.cachedTinyPreview(try XCTUnwrap(last)))
    XCTAssertEqual(media.bytesUsed, one, "Only the explicitly held visible frame may survive")
    held.close()
    XCTAssertEqual(media.bytesUsed, 0)
    media.close()
    XCTAssertNil(media.cachedTinyPreview(try XCTUnwrap(last)))
    try await h.close()
  }
  func testWarmBlurredPreviewIsPresentDuringFirstBindWithTinyDecoderBlocked() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let value = Attachment(
      id: draft.id, relativePath: "remote/fast-scroll-preview.jpg", mime: draft.mime,
      byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
      orientation: draft.orientation, durationMs: draft.durationMs,
      thumbnailKey: draft.thumbnailKey, tinyPreview: try XCTUnwrap(draft.tinyPreview))
    let first: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      _ = media.tinyPreview(value) { continuation.resume(with: $0) }
    }
    let expected = ObjectIdentifier(try XCTUnwrap(first.image))
    first.close()
    let tinyQueue = try XCTUnwrap(Mirror(reflecting: media).children.first {
      $0.label == "tinyPreviewQueue"
    }?.value as? MediaDecodeQueue)
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let network = DispatchSemaphore(value: 0), original = source()
    _ = tinyQueue.submit(work: {
      started.signal()
      _ = release.wait(timeout: .now() + 5)
      return 0
    }, dispose: { _ in }, completion: { _ in })
    media.remoteFile = { _, _, token in
      token.onCancel { network.signal() }
      _ = network.wait(timeout: .now() + 5)
      return (original, "image/jpeg")
    }
    defer { release.signal(); network.signal(); media.close() }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    for kind in [MessageKind.photo, .video] {
      let slot = MediaImageSlot(store: media)
      slot.bind(value, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
        kind: kind, showControls: false)
      let shown = slot.preview()
      XCTAssertNotNil(shown, "A prepared own blur must be visible during bind, before any queue turn")
      if let image = shown?.image {
        XCTAssertEqual(ObjectIdentifier(image), expected, "Reuse the prepared pixels without another decode")
        XCTAssertLessThanOrEqual(max(image.width, image.height), 64)
      }
      shown?.close()
      slot.close()
    }
    release.signal()
    network.signal()
    media.close()
    try await h.close()
  }
  func testVisibleAlbumDoesNotFailBehindPreparedNeighbors() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let container = CALayer()
    container.bounds = CGRect(x: 0, y: 0, width: 390, height: 650)
    let scene = RetainedChatScene(container: container)
    scene.mediaStore = media
    scene.viewport = container.bounds
    scene.imageViewport = container.bounds
    scene.imagePreparationViewport = CGRect(x: 0, y: -2300, width: 390, height: 3100)
    defer { scene.close(); media.close() }
    let directory = h.root.appendingPathComponent("media/remote")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("reference.png")
    let original = try XCTUnwrap(UIImage(contentsOfFile: source().path)?.cgImage)
    let canvas = try XCTUnwrap(CGContext(
      data: nil, width: 1280, height: 1280, bitsPerComponent: 8, bytesPerRow: 5120,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    canvas.draw(original, in: CGRect(x: 0, y: 0, width: 1280, height: 1280))
    let output = try XCTUnwrap(CGImageDestinationCreateWithURL(
      file as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(output, try XCTUnwrap(canvas.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    let byteSize = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
    var attachments: [Attachment] = []
    for index in 0..<7 {
      let name = "pressure-\(index).png"
      try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent(name))
      attachments.append(Attachment(
        id: name, relativePath: "remote/" + name, mime: "image/png", byteSize: byteSize,
        rawWidth: 1280, rawHeight: 1280, orientation: 1, durationMs: nil, thumbnailKey: name))
    }
    let root = h.root
    media.remoteFile = { attachment, preview, _ in
      guard !preview else { throw MediaError.unavailable }
      return (root.appendingPathComponent("media/" + attachment.relativePath), "image/png")
    }
    func fragment(_ id: Int64, photos: [Attachment], y: CGFloat, album: Bool) -> SceneFragment {
      let generation: StudioGeneration? = album ? StudioGeneration(
        stage: .succeeded, model: "image", aspect: "1:1", startedAtMs: nil, error: nil,
        slots: photos.map { .init(id: $0.id, status: .succeeded, blobId: $0.thumbnailKey, progress: 100) }
      ) : nil
      let row = Message(
        id: id, chatID: 1, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 0, kind: .photo, text: "", caption: "", replyToID: nil, revision: 1,
        attachments: photos, studioGeneration: generation)
      let prepared = PreparedText(message: row, key: TextLayoutKey(
        messageID: id, revision: 1, width: 300, fontSize: 17, scale: 3))
      return SceneFragment(prepared: prepared, part: 0,
        frame: CGRect(x: 0, y: y, width: prepared.width, height: prepared.height))
    }
    var neighbors: [SceneFragment] = []
    for index in 0..<3 {
      let y: CGFloat = -1900 + CGFloat(index) * 600
      let item = fragment(Int64(index + 1), photos: [attachments[index]], y: y, album: false)
      neighbors.append(item)
    }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: neighbors))
    func neighborsCached() -> Bool {
      attachments.prefix(3).allSatisfy { value in
        guard let key = media.studioPhotoKey(value),
          let frame = media.cachedThumbnail(attachment: value, key: key) else { return false }
        frame.close()
        return true
      }
    }
    for _ in 0..<400 where !neighborsCached() { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(neighborsCached(), "The pressure fixture must first prepare all three neighbors")
    let visible = fragment(10, photos: Array(attachments.suffix(4)), y: 0, album: true)
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: neighbors + [visible]))
    func ready() -> [Bool] { (0..<4).map { scene.imageReady(10, attachmentIndex: $0) } }
    for _ in 0..<400 where ready().contains(false) { try await Task.sleep(for: .milliseconds(5)) }
    print("KANDINSKY_PREFETCH_PRESSURE ready=\(ready()) bytes=\(media.bytesUsed) peak=\(media.peakBytesUsed)")
    XCTAssertEqual(ready(), [true, true, true, true],
      "Speculative neighbor preparation must not leave one visible result in a failed state")
    XCTAssertTrue(scene.loadActions().filter { $0.0 == 10 }.isEmpty)
    for index in 0..<4 where scene.imageReady(10, attachmentIndex: index) {
      let shown = try XCTUnwrap(scene.preview(10, attachmentIndex: index))
      XCTAssertEqual(shown.image?.width, 1280, "This test must keep original detail")
      shown.close()
    }
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    for attachment in attachments.prefix(3) {
      let key = try XCTUnwrap(media.studioPhotoKey(attachment))
      let frame: PreparedImage = try await withCheckedThrowingContinuation { continuation in
        _ = media.thumbnail(attachment: attachment, key: key, ticket: 0, localOnly: true,
          priority: 0) { _, result in continuation.resume(with: result) }
      }
      frame.close()
    }
    for attachment in attachments.suffix(4) {
      let key = try XCTUnwrap(media.studioPhotoKey(attachment))
      let cached = media.cachedThumbnail(attachment: attachment, key: key)
      XCTAssertNotNil(cached, "A speculative decode must not drop a still displayed cache owner")
      cached?.close()
    }
    media.withNavigationCache {
      scene.advanceGeneration()
      media.releaseIdleImages()
    }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [visible]))
    XCTAssertEqual(ready(), [true, true, true, true],
      "Returning to the same four-photo album must bind every warmed original immediately")
    scene.close()
    media.close()
    try await h.close()
  }

  func testLocalSharpDecodeDoesNotWaitBehindUnrelatedNetworkReads() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let local = attachment(draft)
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    var started = 0
    let file = source()
    media.remoteFile = { _, _, token in
      lock.lock(); started += 1; lock.unlock()
      token.onCancel { gate.signal() }
      _ = gate.wait(timeout: .now() + 1)
      return (file, "image/jpeg")
    }
    var requests: [MediaCancellation] = []
    defer {
      requests.forEach { $0.cancel() }
      gate.signal(); gate.signal()
      media.close()
    }
    for index in 0..<2 {
      let remote = Attachment(
        id: "blocked-\(index)", relativePath: "remote/blocked-\(index).jpg", mime: "image/jpeg",
        byteSize: 1000, rawWidth: 1024, rawHeight: 1024, orientation: 1, durationMs: nil,
        thumbnailKey: "blocked-\(index)")
      requests.append(media.thumbnail(attachment: remote, key: ThumbnailKey(maxPixel: 256), ticket: 0) {
        _, result in try? result.get().close()
      })
    }
    func startedCount() -> Int { lock.lock(); defer { lock.unlock() }; return started }
    for _ in 0..<200 where startedCount() < 2 { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(startedCount(), 2, "Both unrelated network reads must be blocked before timing")
    let began = ProcessInfo.processInfo.systemUptime
    let result: PreparedImage = try await withCheckedThrowingContinuation { c in
      _ = media.thumbnail(attachment: local, key: ThumbnailKey(maxPixel: 256), ticket: 1,
        localOnly: true) { _, value in c.resume(with: value) }
    }
    let seconds = ProcessInfo.processInfo.systemUptime - began
    result.close()
    print("KANDINSKY_LOCAL_BEHIND_NETWORK seconds=\(seconds)")
    XCTAssertLessThan(seconds, 0.15, "A local photo must not wait for unrelated network downloads")
    requests.forEach { $0.cancel() }
    gate.signal(); gate.signal()
    media.close()
    try await h.close()
  }

  func testStudioPhotoStagesUprightJPEGWithinUploadSizeLimit() async throws {
    let harness = try await RepositoryHarness.open()
    let media = MediaStore(store: harness.store)
    defer { media.close() }
    let source = harness.root.appendingPathComponent("rotated-studio.jpg")
    let original = try XCTUnwrap(
      CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
      original, mediaTestImage(2560, 1280), [kCGImagePropertyOrientation: 6] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(original))

    let draft = try await media.stageStudioPhoto(sourceURL: source)
    XCTAssertEqual(draft.mime, "image/jpeg")
    XCTAssertEqual(draft.rawWidth, 1024)
    XCTAssertEqual(draft.rawHeight, 2048)
    XCTAssertEqual(draft.orientation, 1)
    XCTAssertTrue(draft.relativePath.hasPrefix("selections/"))
    let staged = try media.fileURL(draft.relativePath)
    let contents = try Data(contentsOf: staged)
    XCTAssertEqual(draft.byteSize, Int64(contents.count))
    XCTAssertEqual(Array(contents.prefix(2)), [0xff, 0xd8])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: harness.root.appendingPathComponent("media/staging").path), [])
    try await harness.close()
  }
  func testSelectionIntentProtectsOriginalsAndCorruptionStopsRecoveryBeforeDeletion() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), fm = FileManager.default
    defer { media.close() }
    let selected = try await media.stageSelection(sourceURL: source(), mime: "image/jpeg")
    let orphan = try await media.stageSelection(sourceURL: source(), mime: "image/jpeg")
    let camera = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let command = SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: [selected])
    try await h.repo.saveDraft(
      chatID: 2, draft: Draft(text: "Текущий", revision: 5, pendingMediaBatch: [command]))
    try await h.repo.saveDraft(chatID: 2, draft: Draft(text: "Устаревший", revision: 4))
    let current = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(current.text, "Текущий")
    XCTAssertEqual(current.pendingMediaBatch, [command])
    var invalid = command
    invalid.attachments = []
    do {
      try await h.repo.saveDraft(
        chatID: 2, draft: Draft(text: "Недопустимый", revision: 6, pendingMediaBatch: [invalid]))
      XCTFail("Invalid intent must roll back the entire draft transaction")
    } catch { XCTAssertEqual(error as? RepoError, .invalidInput) }
    let unchanged = try await h.repo.draft(chatID: 2)
    XCTAssertEqual(unchanged, current)
    let payload = try await h.store.perform { db -> String in
      let payload = try XCTUnwrap(
        db.rows("SELECT payload FROM media_selection_intents WHERE chatID=2").first?["payload"]?
          .string)
      try db.execute("UPDATE media_selection_intents SET payload='{' WHERE chatID=2")
      return payload
    }
    do {
      try await media.recover()
      XCTFail("Malformed intent must never authorize a deletion sweep")
    } catch { XCTAssertEqual(error as? RepoError, .corrupt) }
    for asset in [selected, orphan, camera] {
      XCTAssertTrue(fm.fileExists(atPath: try media.fileURL(asset.relativePath).path))
    }
    try await h.store.perform { db in
      try db.execute(
        "UPDATE media_selection_intents SET payload=? WHERE chatID=2", [.text(payload)])
    }
    try await media.discardUnpublishedImports([selected, orphan, camera])
    XCTAssertTrue(fm.fileExists(atPath: try media.fileURL(selected.relativePath).path))
    for asset in [orphan, camera] {
      XCTAssertFalse(fm.fileExists(atPath: try media.fileURL(asset.relativePath).path))
    }
    try await media.recover()
    XCTAssertTrue(fm.fileExists(atPath: try media.fileURL(selected.relativePath).path))
    try await h.repo.saveDraft(chatID: 2, draft: Draft(revision: 6))
    try await media.recover()
    XCTAssertFalse(fm.fileExists(atPath: try media.fileURL(selected.relativePath).path))
    try await h.close()
  }
  // Правила прежнего выпуска сохранены независимо от проверяемого способа разрешения пути
  private func previousFileURL(root: URL, relative: String) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.hasPrefix("/"), !parts.isEmpty, !parts.contains(""), !parts.contains(".."),
      !parts.contains(".")
    else { throw MediaError.corrupt }
    let expected = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
      "media")
    let base = expected.resolvingSymlinksInPath().standardizedFileURL
    guard base.path == expected.path else { throw MediaError.corrupt }
    let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else { throw MediaError.corrupt }
    return file
  }
  func testFileResolutionRejectsTraversalAndLiveMediaSymlinkReplacement() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), fm = FileManager.default
    defer { media.close() }
    let base = h.root.appendingPathComponent("media"),
      objects = base.appendingPathComponent("objects"),
      outside = h.root.appendingPathComponent("media-sibling")
    try fm.createDirectory(at: objects, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try fm.copyItem(at: source(), to: objects.appendingPathComponent("probe.jpg"))
    try fm.copyItem(at: source(), to: outside.appendingPathComponent("probe.jpg"))
    try fm.createSymbolicLink(
      at: base.appendingPathComponent("internal"), withDestinationURL: objects)
    try fm.createSymbolicLink(
      at: base.appendingPathComponent("escape"), withDestinationURL: outside)
    for relative in ["objects/probe.jpg", "objects/missing.jpg", "internal/probe.jpg"] {
      let expected =
        relative.hasSuffix("missing.jpg")
        ? h.root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
          "media/objects/missing.jpg")
        : objects.appendingPathComponent("probe.jpg").resolvingSymlinksInPath().standardizedFileURL
      XCTAssertEqual(try media.fileURL(relative), expected)
      XCTAssertEqual(try previousFileURL(root: h.root, relative: relative), expected)
    }
    for relative in [
      "", "/objects/probe.jpg", "../media-sibling/probe.jpg", "objects//probe.jpg",
      "objects/./probe.jpg", "objects/../probe.jpg", "escape/probe.jpg"
    ] {
      XCTAssertThrowsError(try media.fileURL(relative)) {
        XCTAssertEqual($0 as? MediaError, .corrupt)
      }
      XCTAssertThrowsError(try previousFileURL(root: h.root, relative: relative)) {
        XCTAssertEqual($0 as? MediaError, .corrupt)
      }
    }
    let retained = h.root.appendingPathComponent("media-owned")
    try fm.moveItem(at: base, to: retained)
    try fm.createSymbolicLink(at: base, withDestinationURL: outside)
    for relative in ["probe.jpg", "missing.jpg"] {
      XCTAssertThrowsError(try media.fileURL(relative)) {
        XCTAssertEqual($0 as? MediaError, .corrupt)
      }
      XCTAssertThrowsError(try previousFileURL(root: h.root, relative: relative)) {
        XCTAssertEqual($0 as? MediaError, .corrupt)
      }
    }
    try fm.removeItem(at: base)
    try fm.moveItem(at: retained, to: base)
    XCTAssertEqual(
      try media.fileURL("objects/probe.jpg"),
      objects.appendingPathComponent("probe.jpg").resolvingSymlinksInPath().standardizedFileURL)
    try await h.close()
  }
  func testFileResolutionAvoidsRedundantMediaRootWalk() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), fm = FileManager.default
    defer { media.close() }
    let objects = h.root.appendingPathComponent("media/objects")
    try fm.createDirectory(at: objects, withIntermediateDirectories: true)
    try fm.copyItem(at: source(), to: objects.appendingPathComponent("probe.jpg"))
    let path = "objects/probe.jpg", iterations = 300
    for _ in 0..<32 {
      _ = try previousFileURL(root: h.root, relative: path)
      _ = try media.fileURL(path)
    }
    func batch(_ resolve: () throws -> URL) throws -> Double {
      let start = ProcessInfo.processInfo.systemUptime
      var characters = 0
      for _ in 0..<iterations {
        characters += try autoreleasepool { try resolve().path.utf16.count }
      }
      XCTAssertGreaterThan(characters, iterations * 10)
      return ProcessInfo.processInfo.systemUptime - start
    }
    // Сравниваем медиану пар, чтобы случайная пауза планировщика не решала исход замера.
    var ratios: [Double] = []
    for _ in 0..<5 {
      let referenceFirst = try batch { try previousFileURL(root: h.root, relative: path) }
      let candidateFirst = try batch { try media.fileURL(path) }
      let candidateSecond = try batch { try media.fileURL(path) }
      let referenceSecond = try batch { try previousFileURL(root: h.root, relative: path) }
      ratios.append((candidateFirst + candidateSecond) / (referenceFirst + referenceSecond))
    }
    let ratio = ratios.sorted()[ratios.count / 2]
    print("KANDINSKY_PATH_COST iterations=\(iterations) ratios=\(ratios) median=\(ratio)")
    XCTAssertLessThanOrEqual(
      ratio, 0.9,
      "The scrolling media resolver must remove redundant filesystem walks, not only move their cost"
    )
    try await h.close()
  }
  private enum QueuedPathRequest: Equatable { case original, localPlayback, remotePlayback }
  func testOriginalPathValidationWaitsForWorkerAdmission() async throws {
    try await checkQueuedPath(.original)
  }
  func testLocalPlaybackPathValidationWaitsForWorkerAdmission() async throws {
    try await checkQueuedPath(.localPlayback)
  }
  func testRemotePlaybackPathValidationWaitsForWorkerAdmission() async throws {
    try await checkQueuedPath(.remotePlayback)
  }
  private func checkQueuedPath(_ mode: QueuedPathRequest) async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let outside = h.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: h.root.appendingPathComponent("media"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source(), to: outside.appendingPathComponent("payload"))
    try FileManager.default.createSymbolicLink(
      at: h.root.appendingPathComponent("media/escape"), withDestinationURL: outside)
    let started = expectation(description: "Two admitted reads"),
      finished = expectation(description: "Both reads retire")
    started.expectedFulfillmentCount = 2
    finished.expectedFulfillmentCount = 2
    let hold = DispatchSemaphore(value: 0), file = source()
    media.remoteFile = { attachment, _, _ in
      guard attachment.id != "escape" else {
        XCTFail("An escaped path reached the file resolver")
        throw MediaError.corrupt
      }
      started.fulfill()
      guard hold.wait(timeout: .now() + 5) == .success else { throw MediaError.unavailable }
      return (file, "image/jpeg")
    }
    if mode == .remotePlayback {
      media.remotePlayback = { _, _ in
        XCTFail("An escaped path reached the player resolver")
        throw MediaError.corrupt
      }
    }
    defer {
      hold.signal()
      hold.signal()
      media.close()
    }
    var blockingReads: [Task<Void, Never>] = []
    for n in 0..<2 {
      let a = Attachment(
        id: "held-\(n)", relativePath: "remote/held-\(n).jpg", mime: "image/jpeg", byteSize: 100,
        rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: nil, thumbnailKey: "held-\(n)")
      blockingReads.append(Task {
        _ = try? await media.ensureOriginal(a)
        finished.fulfill()
      })
    }
    await fulfillment(of: [started], timeout: 2)
    let premature = expectation(description: "Filesystem inspection waits for worker admission")
    premature.isInverted = true
    let rejected = expectation(description: "Owned path rules reject the escape after admission")
    var admitted = false, replies = 0
    let expected: MediaError = .corrupt
    func complete(_ error: Error?) {
      replies += 1
      if !admitted { premature.fulfill() }
      XCTAssertEqual(
        error as? MediaError, expected, "Existing path-error semantics must remain stable")
      rejected.fulfill()
    }
    let a = Attachment(
      id: "escape", relativePath: "escape/payload", mime: "video/mp4", byteSize: 100, rawWidth: 64,
      rawHeight: 64, orientation: 1, durationMs: nil, thumbnailKey: "escape")
    var task: Task<Void, Never>?
    task = Task {
      do {
        if mode == .original {
          _ = try await media.ensureOriginal(a)
        } else {
          let value = try await media.playbackSource(a)
          value.close()
        }
        complete(nil)
      } catch { complete(error) }
    }
    await fulfillment(of: [premature], timeout: 0.1)
    admitted = true
    hold.signal()
    hold.signal()
    await fulfillment(of: [finished, rejected], timeout: 3)
    for read in blockingReads { await read.value }
    await task?.value
    XCTAssertEqual(replies, 1)
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  func testThumbnailPathValidationWaitsForWorkerAdmissionAndRejectsEscape() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let outside = h.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: h.root.appendingPathComponent("media"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source(), to: outside.appendingPathComponent("photo.jpg"))
    let escape = h.root.appendingPathComponent("media/escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
    let started = expectation(description: "Two admitted reads"),
      finished = expectation(description: "Both reads retire")
    started.expectedFulfillmentCount = 2
    finished.expectedFulfillmentCount = 2
    let hold = DispatchSemaphore(value: 0), file = source()
    media.remoteFile = { attachment, _, _ in
      guard attachment.id != "escape" else {
        XCTFail("Escaped paths cannot reach the network resolver")
        throw MediaError.corrupt
      }
      started.fulfill()
      guard hold.wait(timeout: .now() + 5) == .success else { throw MediaError.unavailable }
      return (file, "image/jpeg")
    }
    defer {
      hold.signal()
      hold.signal()
      media.close()
    }
    func value(_ id: String, _ path: String) -> Attachment {
      Attachment(
        id: id, relativePath: path, mime: "image/jpeg", byteSize: 100, rawWidth: 64, rawHeight: 64,
        orientation: 1, durationMs: nil, thumbnailKey: id)
    }
    for index in 0..<2 {
      _ = media.thumbnail(
        attachment: value("held-\(index)", "remote/held-\(index).jpg"),
        key: ThumbnailKey(maxPixel: 64), ticket: index
      ) { _, result in
        if case let .success(frame) = result { frame.close() }
        finished.fulfill()
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let premature = expectation(
      description: "Path validation must wait for bounded worker admission")
    premature.isInverted = true
    let rejected = expectation(description: "Escaped path rejected after admission")
    var admitted = false, replies = 0
    _ = media.thumbnail(
      attachment: value("escape", "escape/photo.jpg"), key: ThumbnailKey(maxPixel: 64), ticket: 3
    ) { _, result in
      replies += 1
      if !admitted { premature.fulfill() }
      switch result {
      case let .success(frame):
        frame.close()
        XCTFail("Escaped source accepted")
      case let .failure(error): XCTAssertEqual(error as? MediaError, .corrupt)
      }
      rejected.fulfill()
    }
    await fulfillment(of: [premature], timeout: 0.1)
    admitted = true
    hold.signal()
    hold.signal()
    await fulfillment(of: [finished, rejected], timeout: 3)
    XCTAssertEqual(replies, 1)
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  func testDecodedThumbnailSurvivesUnavailableSourceDirectory() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg"),
      value = attachment(draft)
    let first = try await frame(media, value), pixels = try XCTUnwrap(first.image)
    first.close()
    let directory = h.root.appendingPathComponent("media/objects"),
      retired = h.root.appendingPathComponent("media/objects-retired")
    let outside = h.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: source(),
      to: outside.appendingPathComponent(URL(fileURLWithPath: draft.relativePath).lastPathComponent)
    )
    try FileManager.default.moveItem(at: directory, to: retired)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.moveItem(at: retired, to: directory)
    }
    let cached = try await frame(media, value)
    XCTAssertTrue(
      cached.image === pixels, "An owned decoded lease must not need another filesystem traversal")
    cached.close()
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  private func source() -> URL {
    let root = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
    let manifest =
      try! JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let files = manifest["files"] as! [[String: Any]]
    let name = files.first { $0["mime"] as? String == "image/jpeg" }!["fileName"] as! String
    return root.appendingPathComponent("media/" + name)
  }
  /// Сохраняет путь, размеры, поворот, длительность и ключ подложки без повторного чтения файла.
  private func attachment(_ d: AttachmentDraft) -> Attachment {
    Attachment(
      id: d.id, relativePath: d.relativePath, mime: d.mime, byteSize: d.byteSize,
      rawWidth: d.rawWidth, rawHeight: d.rawHeight, orientation: d.orientation,
      durationMs: d.durationMs, thumbnailKey: d.thumbnailKey)
  }
  private func frame(_ media: MediaStore, _ a: Attachment) async throws -> PreparedImage {
    try await withCheckedThrowingContinuation { c in
      _ = media.thumbnail(attachment: a, key: ThumbnailKey(maxPixel: 1024), ticket: 42) {
        ticket, result in
        XCTAssertEqual(ticket, 42)
        c.resume(with: result)
      }
    }
  }
  func testCachedPhotoBindsImmediatelyWithoutAnotherPreviewAllocation() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    var value = attachment(draft)
    value.tinyPreview = try XCTUnwrap(draft.tinyPreview)
    let prepared = try await frame(media, value), image = try XCTUnwrap(prepared.image)
    prepared.close()
    let bytes = media.bytesUsed, slot = MediaImageSlot(store: media)
    slot.bind(
      value, frame: CGRect(x: 0, y: 0, width: 260, height: 200), maxPixel: 1024, kind: .photo)
    print("KANDINSKY_CACHED_PHOTO immediate=\(slot.ready) before=\(bytes) after=\(media.bytesUsed)")
    XCTAssertTrue(
      slot.ready, "An already decoded photo must be visible before the next run-loop turn")
    XCTAssertTrue(
      (slot.layer.sublayers?.first?.contents as AnyObject?) === image,
      "The existing decoded pixels must reach the native layer")
    XCTAssertEqual(
      media.bytesUsed, bytes,
      "Binding a cached full frame must not allocate a tiny preview or decode another image")
    slot.close()
    media.close()
    for _ in 0..<100 where media.bytesUsed > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  func testViewerDecodeUsesOriginalAndDoesNotReuseTimelinePreview() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    func imageFile(_ name: String, _ width: Int, _ height: Int) throws -> URL {
      let url = h.root.appendingPathComponent(name),
        destination = try XCTUnwrap(
          CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, mediaTestImage(width, height), nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      return url
    }
    let original = try imageFile("original.jpg", 2048, 1536),
      preview = try imageFile("preview.jpg", 256, 192)
    var modes: [Bool] = []
    media.remoteFile = { _, isPreview, _ in
      modes.append(isPreview)
      return (isPreview ? preview : original, "image/jpeg")
    }
    let a = Attachment(
      id: "viewer-original", relativePath: "remote/viewer-original.jpg", mime: "image/jpeg",
      byteSize: 100, rawWidth: 2048, rawHeight: 1536, orientation: 1, durationMs: nil,
      thumbnailKey: "viewer-original")
    let small = try await frame(media, a)
    XCTAssertEqual(small.image?.width, 256)
    small.close()
    let full: PreparedImage = try await withCheckedThrowingContinuation { c in
      _ = media.thumbnail(attachment: a, key: ThumbnailKey(maxPixel: 2048), ticket: 1) { _, value in
        c.resume(with: value)
      }
    }
    XCTAssertEqual(
      full.image?.width, 2048, "The viewer needs the server original, not the cached timeline image"
    )
    XCTAssertEqual(modes, [true, false], "Full-screen decode must resolve the original source")
    let slot = MediaImageSlot(store: media)
    slot.bind(
      a, frame: CGRect(x: 0, y: 0, width: 390, height: 292.5), maxPixel: 2048, cornerRadius: 0)
    for _ in 0..<100 where !slot.ready { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(
      slot.ready, "Original pixels must reach the native image layer, not only the decode cache")
    XCTAssertNotNil(slot.layer.sublayers?.first?.contents)
    slot.close()
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    full.close()
    media.close()
    try await h.close()
  }
  func testStudioPhotoTimelineAndGalleryReuseOriginalPixels() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let timeline = MediaImageSlot(store: media)
    let gallery = MediaImageSlot(store: media)
    defer {
      gallery.close()
      timeline.close()
      media.close()
    }
    func fixture(_ name: String, _ width: Int, _ height: Int) throws -> URL {
      let url = h.root.appendingPathComponent(name)
      let output = try XCTUnwrap(
        CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(output, mediaTestImage(width, height), nil)
      XCTAssertTrue(CGImageDestinationFinalize(output))
      return url
    }
    let original = try fixture("studio-full.jpg", 1280, 768)
    let preview = try fixture("studio-small.jpg", 256, 154)
    var requests = [Bool]()
    media.remoteFile = { _, small, _ in
      requests.append(small)
      return (small ? preview : original, "image/jpeg")
    }
    let photo = Attachment(
      id: "studio", relativePath: "remote/studio.jpg", mime: "image/jpeg", byteSize: 200_000,
      rawWidth: 1280, rawHeight: 768, orientation: 1, durationMs: nil, thumbnailKey: "studio")
    let cell = CGRect(x: 0, y: 0, width: 350, height: 210)
    timeline.bind(photo, frame: cell, maxPixel: 512, kind: .photo)
    for _ in 0..<200 where timeline.loading { try await Task.sleep(nanoseconds: 10_000_000) }
    let frame = try XCTUnwrap(timeline.preview())
    defer { frame.close() }
    XCTAssertEqual(frame.image?.width, 1280)
    XCTAssertEqual(frame.image?.height, 768)
    gallery.bind(photo, frame: cell, maxPixel: 384, showControls: false)
    XCTAssertTrue(gallery.ready)
    let reopened = gallery.preview()
    defer { reopened?.close() }
    XCTAssertTrue(frame.image === reopened?.image)
    XCTAssertEqual(requests, [false])
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    frame.close()
    reopened?.close()
    gallery.close()
    timeline.close()
    media.trimMemory()
    let restored = MediaImageSlot(store: media)
    defer { restored.close() }
    restored.bind(photo, frame: cell, maxPixel: 512, kind: .photo)
    for _ in 0..<200 where restored.loading { try await Task.sleep(nanoseconds: 10_000_000) }
    let restoredFrame = try XCTUnwrap(restored.preview())
    XCTAssertEqual(restoredFrame.image?.width, 1280)
    XCTAssertEqual(restoredFrame.image?.height, 768)
    restoredFrame.close()
    XCTAssertLessThanOrEqual(media.bytesUsed, 24 * 1024 * 1024)
    restored.close()
    media.close()
    try await h.close()
  }
  func testFourPhotoAlbumsCanOverlapDuringChatNavigation() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let original = h.root.appendingPathComponent("album.png")
    let output = try XCTUnwrap(
      CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil))
    let sourceImage = try XCTUnwrap(UIImage(contentsOfFile: source().path)?.cgImage)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    let gate = DispatchSemaphore(value: 0)
    media.remoteFile = { attachment, preview, _ in
      guard !preview else { throw MediaError.unavailable }
      if attachment.id.hasPrefix("new"), gate.wait(timeout: .now() + 8) != .success {
        throw MediaError.interrupted
      }
      return (original, "image/png")
    }
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 650)
    let oldLayer = CALayer()
    let newLayer = CALayer()
    oldLayer.bounds = bounds
    newLayer.bounds = bounds
    let old = RetainedChatScene(container: oldLayer)
    let new = RetainedChatScene(container: newLayer)
    old.mediaStore = media
    new.mediaStore = media
    func snapshot(_ scene: RetainedChatScene, id: MessageID, prefix: String) -> SceneSnapshot {
      let photos = (0..<4).map { index in
        let key = "\(prefix)-\(index)"
        return Attachment(
          id: key, relativePath: "remote/\(key).png", mime: "image/png", byteSize: 1000,
          rawWidth: 1024, rawHeight: 1024, orientation: 1, durationMs: nil, thumbnailKey: key)
      }
      let generation = StudioGeneration(
        stage: .succeeded, model: "image", aspect: "1:1", startedAtMs: nil, error: nil,
        slots: photos.map {
          .init(id: $0.id, status: .succeeded, blobId: $0.thumbnailKey, progress: 100)
        })
      let row = Message(
        id: id, chatID: id, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 0,
        kind: .photo, text: "", caption: "", replyToID: nil, revision: 1, attachments: photos,
        studioGeneration: generation)
      let prepared = PreparedText(
        message: row,
        key: TextLayoutKey(messageID: id, revision: 1, width: 300, fontSize: 17, scale: 3))
      return SceneSnapshot(
        ticket: scene.ticket,
        fragments: [
          SceneFragment(
            prepared: prepared, part: 0,
            frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
        ])
    }
    /// Возвращает отдельное состояние каждой ячейки, чтобы частичная готовность не скрылась за общим
    /// признаком.
    func presented(_ scene: RetainedChatScene, _ id: MessageID) async throws -> [Bool] {
      let deadline = Date().addingTimeInterval(3)
      func state() -> [Bool] { (0..<4).map { scene.imageReady(id, attachmentIndex: $0) } }
      while state().contains(false), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      return state()
    }
    defer {
      for _ in 0..<4 { gate.signal() }
      old.close()
      new.close()
      media.close()
    }
    old.apply(snapshot(old, id: 1, prefix: "old"))
    let oldReady = try await presented(old, 1)
    XCTAssertEqual(oldReady, [true, true, true, true])
    new.apply(snapshot(new, id: 2, prefix: "new"))
    for _ in 0..<4 { gate.signal() }
    let newReady = try await presented(new, 2)
    XCTAssertEqual(
      newReady, [true, true, true, true],
      "All four decoded photos should coexist with the outgoing album")
    XCTAssertTrue(new.loadActions().isEmpty)
    func assertOriginalDetail(_ scene: RetainedChatScene, _ id: MessageID) throws {
      for index in 0..<4 {
        let frame = try XCTUnwrap(scene.preview(id, attachmentIndex: index))
        defer { frame.close() }
        XCTAssertEqual(frame.image?.width, 1024, "Album photo \(index) must retain original detail")
        XCTAssertEqual(frame.image?.height, 1024)
      }
    }
    try assertOriginalDetail(old, 1)
    try assertOriginalDetail(new, 2)
    new.apply(snapshot(new, id: 2, prefix: "new"))
    try assertOriginalDetail(new, 2)
    let reopened = RetainedChatScene(container: CALayer())
    reopened.mediaStore = media
    defer { reopened.close() }
    reopened.apply(snapshot(reopened, id: 2, prefix: "new"))
    let reopenedReady = try await presented(reopened, 2)
    XCTAssertEqual(reopenedReady, [true, true, true, true])
    try assertOriginalDetail(reopened, 2)
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    old.close()
    new.close()
    reopened.close()
    media.trimMemory()
    for _ in 0..<4 { gate.signal() }
    let afterPressure = RetainedChatScene(container: CALayer())
    afterPressure.mediaStore = media
    defer { afterPressure.close() }
    afterPressure.apply(snapshot(afterPressure, id: 2, prefix: "new"))
    let pressureReady = try await presented(afterPressure, 2)
    XCTAssertEqual(pressureReady, [true, true, true, true])
    try assertOriginalDetail(afterPressure, 2)
    XCTAssertLessThanOrEqual(media.bytesUsed, 24 * 1024 * 1024)
    afterPressure.close()
    media.close()
    try await h.close()
  }
  func testTransferredPhotoIsNotReplacedByALateMicroPreview() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    var value = attachment(draft)
    value.tinyPreview = try XCTUnwrap(draft.tinyPreview)
    let full = try await frame(media, value), expected = try XCTUnwrap(full.image)
    XCTAssertGreaterThan(max(expected.width, expected.height), 64)
    media.releaseIdleImages()
    let held = DispatchSemaphore(value: 0), file = source()
    media.remoteFile = { _, _, token in
      token.onCancel { held.signal() }
      _ = held.wait(timeout: .now() + 5)
      return (file, "image/jpeg")
    }
    let slot = MediaImageSlot(store: media)
    defer {
      held.signal()
      slot.close()
      full.close()
      media.close()
    }
    slot.bind(
      value, frame: CGRect(x: 0, y: 0, width: 260, height: 200), maxPixel: 1024, showControls: false
    )
    slot.seed(try XCTUnwrap(full.retained()))
    let barrier: PreparedImage = try await withCheckedThrowingContinuation { c in
      _ = media.tinyPreview(value) { c.resume(with: $0) }
    }
    barrier.close()
    await Task.yield()
    let shown = try XCTUnwrap(slot.preview())
    defer { shown.close() }
    XCTAssertTrue(
      shown.image === expected,
      "A late tiny JPEG must not downgrade the image transferred from the chat")
    shown.close()
    slot.close()
    full.close()
    held.signal()
    media.close()
    try await h.close()
  }
  func testCancelledManualReservationAndCaptureStillWaitForRetiringNativePreview() async throws {
    let admission = MediaAdmission(), replacement = MediaAdmission()
    var lifetime: PreviewLifetime!
    let lease = try XCTUnwrap(MediaAdmission.reservePreview(stop: { lifetime.retire() }))
    lifetime = PreviewLifetime(lease)
    lifetime.begin()
    defer {
      lifetime.retire()
      admission.close()
      replacement.close()
    }
    let cancelled = expectation(description: "pending manual owner cancelled exactly once")
    var replies = 0
    let request = admission.requestPlayback { result in
      replies += 1
      if case .success = result { XCTFail("Native preview has not acknowledged retirement") }
      cancelled.fulfill()
    }
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 1)
    XCTAssertNil(MediaAdmission.reservePreview(stop: {}))
    request.cancel()
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(replies, 1)
    let granted = expectation(description: "capture after actual preview callback"),
      tooSoon = expectation(description: "capture cannot overtake native retirement")
    tooSoon.isInverted = true
    var capture: CaptureLease?, mayGrant = false
    _ = replacement.acquire(.photo) { result in
      capture = try? result.get()
      if capture != nil {
        granted.fulfill()
        if !mayGrant { tooSoon.fulfill() }
      }
    }
    await fulfillment(of: [tooSoon], timeout: 0.1)
    XCTAssertNil(capture)
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 1)
    mayGrant = true
    lifetime.end()
    await fulfillment(of: [granted], timeout: 2)
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    capture?.release()
  }
  func testCaptureAdmissionWaitsForProvenReleaseAndRejectsLateGrant() async throws {
    let admission = MediaAdmission()
    var stopped: (() -> Void)?
    admission.installPlaybackStopper { stopped = $0 }
    let playback: PlaybackLease = try await withCheckedThrowingContinuation { c in
      _ = admission.requestPlayback { c.resume(with: $0) }
    }
    let granted = expectation(description: "capture after release")
    var capture: CaptureLease?
    _ = admission.acquire(.photo) { result in
      capture = try? result.get()
      granted.fulfill()
    }
    let second: Result<CaptureLease, Error> = await withCheckedContinuation { c in
      _ = admission.acquire(.photo) { c.resume(returning: $0) }
    }
    XCTAssertThrowsError(try second.get())
    XCTAssertNil(capture)
    stopped?()
    XCTAssertNil(capture)
    XCTAssertEqual(admission.playbackActiveCount, 1)
    playback.release()
    await fulfillment(of: [granted], timeout: 2)
    XCTAssertNotNil(capture)
    XCTAssertEqual(admission.captureActiveCount, 1)
    capture?.release()
    admission.close()
    let late = MediaAdmission()
    var lateStop: (() -> Void)?
    late.installPlaybackStopper { lateStop = $0 }
    let owner: PlaybackLease = try await withCheckedThrowingContinuation { c in
      _ = late.requestPlayback { c.resume(with: $0) }
    }
    let cancelled = expectation(description: "late admission cancelled")
    var replies = 0
    _ = late.acquire(.photo) { result in
      replies += 1
      if case .success = result { XCTFail("closed admission granted") }
      cancelled.fulfill()
    }
    late.close()
    lateStop?()
    owner.release()
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(late.captureActiveCount, 0)
  }
  func testCrashRecoveryDiskFullAndLostReplyPreserveReferencedOriginal() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let original = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let first = try await h.repo.send(
      SendCommand(operationID: "media-one", chatID: 2, kind: .photo, attachments: [original]))
    XCTAssertEqual(first.inserted.first?.attachments.first?.relativePath, original.relativePath)
    for fault in [RepoFault.beforeRename, .afterRename] {
      h.faults.arm(fault)
      do {
        _ = try await media.stage(sourceURL: source(), mime: "image/jpeg")
        XCTFail("stage fault expected")
      } catch {}
      try await media.recover()
      XCTAssertTrue(
        FileManager.default.fileExists(
          atPath: h.root.appendingPathComponent("media/" + original.relativePath).path))
      let files = try FileManager.default.contentsOfDirectory(
        atPath: h.root.appendingPathComponent("media/objects").path)
      XCTAssertEqual(files.count, 1)
    }
    let full = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    h.faults.arm(.storageFull)
    do {
      _ = try await h.repo.send(
        SendCommand(operationID: "media-full", chatID: 2, kind: .photo, attachments: [full]))
      XCTFail("full expected")
    } catch {}
    try await media.recover()
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: h.root.appendingPathComponent("media/" + full.relativePath).path))
    let lost = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    h.faults.arm(.afterCommitBeforeReply)
    let command = SendCommand(operationID: "media-lost", chatID: 2, kind: .photo, attachments: [lost])
    do {
      _ = try await h.repo.send(command)
      XCTFail("lost reply expected")
    } catch {}
    try await media.recover()
    let retry = try await h.repo.send(command)
    XCTAssertNotNil(retry.inserted.first)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 2)
    XCTAssertEqual(try h.integrity(), "ok")
    media.close()
    try await h.close()
  }
  /// Повреждённый исходник не должен импортироваться или нарушать предел памяти.
  func testRealImageDownsampleCorruptionAndStaleMailbox() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let large = h.root.appendingPathComponent("huge.jpg")
    let destination = CGImageDestinationCreateWithURL(
      large as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, mediaTestImage(4032, 3024), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let draft = try await media.stage(sourceURL: large, mime: "image/jpeg")
    let decoded = try await frame(media, attachment(draft))
    let image = try XCTUnwrap(decoded.image)
    XCTAssertLessThanOrEqual(max(image.width, image.height), 1024)
    XCTAssertEqual(decoded.orientation, 1)
    XCTAssertNotNil(
      PhotoPresentation.filling(
        rawWidth: image.width, rawHeight: image.height, orientation: 1, width: 200, height: 200))
    let mailbox = MediaSurfaceMailbox<PreparedImage>(
      schedule: { DispatchQueue.main.async(execute: $0) }, render: { _ in })
    let binding = try XCTUnwrap(mailbox.begin())
    mailbox.clear()
    XCTAssertFalse(mailbox.offer(decoded, binding: binding, sequence: 1))
    decoded.close()
    XCTAssertEqual(decoded.closeCount, 1)
    mailbox.close()
    mailbox.flush()
    let corrupt = h.root.appendingPathComponent("corrupt.jpg")
    try Data("not an image".utf8).write(to: corrupt)
    do {
      _ = try await media.stage(sourceURL: corrupt, mime: "image/jpeg")
      XCTFail("corrupt accepted")
    } catch {}
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    media.close()
    try await h.close()
  }
  /// После закрытия каждый запрос должен завершиться один раз, а начатые результаты должны освободиться.
  func testDecodeQueueHasTwoWorkersAndSixteenPending() async throws {
    let queue = MediaDecodeQueue()
    let hold = DispatchSemaphore(value: 0)
    let started = expectation(description: "two native jobs")
    started.expectedFulfillmentCount = 2
    let finished = expectation(description: "all completed once")
    finished.expectedFulfillmentCount = 21
    let lock = NSLock()
    var probes: [NativeDecodeProbe] = []
    for _ in 0..<21 {
      _ = queue.submit(
        work: {
          let value = NativeDecodeProbe()
          lock.lock()
          probes.append(value)
          let count = probes.count
          lock.unlock()
          if count <= 2 { started.fulfill() }
          hold.wait()
          return value
        }, dispose: { $0.close() },
        completion: { result in
          if case let .success(v) = result {
            v.close()
            XCTFail("closed queue published")
          }
          finished.fulfill()
        })
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(queue.runningCount, 2)
    XCTAssertEqual(queue.pendingCount, 16)
    queue.close()
    hold.signal()
    hold.signal()
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertEqual(probes.count, 2)
    XCTAssertTrue(probes.allSatisfy { $0.closeCount == 1 })
  }
  func testAllEightEXIFOrientationsAreAppliedOnce() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let w = 40, height = 24
    let colors: [[UInt8]] = [
      [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]
    ]
    var bytes = [UInt8](repeating: 0, count: w * height * 4)
    for y in 0..<height {
      for x in 0..<w {
        let color = colors[(y < height / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)]
        for c in 0..<4 { bytes[(y * w + x) * 4 + c] = color[c] }
      }
    }
    let data = Data(bytes) as CFData
    let raw = CGImage(
      width: w, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(
        .byteOrder32Big), provider: CGDataProvider(data: data)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    let expected = [
      [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1], [0, 2, 1, 3], [2, 0, 3, 1],
      [3, 1, 2, 0], [1, 3, 0, 2]
    ]
    for orientation in 1...8 {
      let url = h.root.appendingPathComponent("orientation-\(orientation).jpg")
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(
        destination, raw,
        [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0]
          as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      let draft = try await media.stage(sourceURL: url, mime: "image/jpeg")
      XCTAssertEqual(draft.rawWidth, 40)
      XCTAssertEqual(draft.rawHeight, 24)
      XCTAssertEqual(draft.orientation, orientation)
      let value = try await frame(media, attachment(draft))
      let image = try XCTUnwrap(value.image)
      XCTAssertEqual(image.width, orientation >= 5 ? 24 : 40)
      XCTAssertEqual(image.height, orientation >= 5 ? 40 : 24)
      XCTAssertEqual(value.orientation, 1)
      let pixels = CFDataGetBytePtr(image.dataProvider!.data!)!
      for (n, point) in [
        (4, 4), (image.width - 5, 4), (4, image.height - 5), (image.width - 5, image.height - 5)
      ].enumerated() {
        let offset = point.1 * image.bytesPerRow + point.0 * 4
        for c in 0..<3 {
          XCTAssertEqual(
            Int(pixels[offset + c]), Int(colors[expected[orientation - 1][n]][c]), accuracy: 25,
            "orientation \(orientation) corner \(n) component \(c)")
        }
      }
      value.close()
    }
    media.close()
    try await h.close()
  }
  func testUnreadableSourceAndRecoveryCannotFollowDirectorySymlink() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let denied = h.root.appendingPathComponent("denied.jpg")
    try FileManager.default.copyItem(at: source(), to: denied)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path)
    }
    do {
      _ = try await media.stage(sourceURL: denied, mime: "image/jpeg")
      XCTFail("unreadable source accepted")
    } catch { XCTAssertEqual(error as? MediaError, MediaError.permissionDenied) }
    let outside = h.root.appendingPathComponent("preserved")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let original = outside.appendingPathComponent("original.txt")
    try Data("keep original".utf8).write(to: original)
    let objects = h.root.appendingPathComponent("media/objects")
    try FileManager.default.removeItem(at: objects)
    try FileManager.default.createSymbolicLink(at: objects, withDestinationURL: outside)
    do {
      try await media.recover()
      XCTFail("symlink recovery accepted")
    } catch { XCTAssertEqual(error as? MediaError, MediaError.corrupt) }
    XCTAssertEqual(try String(contentsOf: original), "keep original")
    try FileManager.default.removeItem(at: objects)
    media.close()
    try await h.close()
  }

  func testNativeMediaFormatsStagePersistAndDecodePosters() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let root = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
    let files = manifest["files"] as! [[String: Any]]
    for (mime, kind) in [("video/mp4", MessageKind.video), ("image/jpeg", .photo)] {
      let item = try XCTUnwrap(files.first { $0["mime"] as? String == mime })
      print("MEDIA_FORMAT stage", mime)
      let d = try await media.stage(
        sourceURL: root.appendingPathComponent("media/" + (item["fileName"] as! String)), mime: mime
      )
      if mime.hasPrefix("video/") { XCTAssertGreaterThan(d.durationMs ?? 0, 0) }
      print("MEDIA_FORMAT metadata", mime, d.durationMs as Any, d.rawWidth, d.rawHeight)
      let preview = try await frame(media, attachment(d))
      XCTAssertNotNil(preview.image)
      preview.close()
      print("MEDIA_FORMAT commit", mime)
      _ = try await h.repo.send(
      SendCommand(operationID: "format-" + mime, chatID: 2, kind: kind, attachments: [d]))
    }
    let rows = try await h.repo.history(PageRequest(chatID: 2))
    XCTAssertEqual(rows.rows.map(\.kind), [.video, .photo])
    XCTAssertTrue(rows.rows.allSatisfy { $0.attachments.count == 1 })
    media.close()
    try await h.close()
  }
  func testNativeLayerLeaseSurvivesCacheCloseUntilDetach() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let d = try await media.stage(sourceURL: source(), mime: "image/jpeg"),
      value = try await frame(media, attachment(d))
    let layer = CALayer()
    layer.contents = value.image
    XCTAssertNotNil(layer.contents)
    media.close()
    XCTAssertNotNil(value.image)
    XCTAssertGreaterThan(media.bytesUsed, 0)
    layer.contents = nil
    value.close()
    XCTAssertEqual(media.bytesUsed, 0)
    XCTAssertEqual(value.closeCount, 1)
    try await h.close()
  }

  func testSystemMemoryWarningReleasesIdleDecodedCache() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let d = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let value = try await frame(media, attachment(d))
    value.close()
    XCTAssertGreaterThan(
      media.bytesUsed, 0, "The cache must contain real decoded pixels before pressure")
    NotificationCenter.default.post(
      name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
    XCTAssertEqual(media.bytesUsed, 0, "System memory pressure must reach the shared media cache")
    media.close()
    try await h.close()
  }

  /// После закрытия разговора требует освобождения неиспользуемых сохранённых пикселей.
  func testChatCloseReleasesIdleDecodedCache() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media), host = ChatScrollHost()
    host.configurePlayback(c, media: media)
    let d = try await media.stage(sourceURL: source(), mime: "image/jpeg"),
      value = try await frame(media, attachment(d))
    value.close()
    XCTAssertGreaterThan(media.bytesUsed, 0)
    host.close()
    XCTAssertEqual(media.bytesUsed, 0, "Leaving the chat must release idle decoded cache ownership")
    c.close()
    media.close()
    admission.close()
    try await h.close()
  }

  func testSerialScrollBurstKeepsOnlySmallDecodedHotSet() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    var one = 0
    for _ in 0..<24 {
      let d = try await media.stage(sourceURL: source(), mime: "image/jpeg"),
        value = try await frame(media, attachment(d))
      one = value.image!.bytesPerRow * value.image!.height
      value.close()
    }
    XCTAssertLessThanOrEqual(
      media.bytesUsed, 16 * one, "Serial scroll must not retain every decoded preview")
    media.close()
    try await h.close()
  }

}
