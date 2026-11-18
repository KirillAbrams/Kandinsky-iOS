import XCTest
import ImageIO
@testable import Kandinsky

@MainActor final class MediaMetadataTests: XCTestCase {
  func testRebindingPhotoKeepsSharpPixelsAndRejectsLateBlur() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let slot = MediaImageSlot(store: media)
    defer { slot.close(); media.close() }
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
    var attachment = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.id)
    attachment.tinyPreview = try XCTUnwrap(draft.tinyPreview)
    let frame = CGRect(x: 0, y: 0, width: 210, height: 160)
    let tiny: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      _ = media.tinyPreview(attachment) { continuation.resume(with: $0) }
    }
    let sharp: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      _ = media.thumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: 256), ticket: 0) {
        _, result in continuation.resume(with: result)
      }
    }
    defer { tiny.close(); sharp.close() }
    slot.bind(attachment, frame: frame, maxPixel: 1024, kind: .photo)
    slot.seed(try XCTUnwrap(tiny.retained()))
    slot.seed(try XCTUnwrap(sharp.retained()))
    XCTAssertTrue(slot.hasSharpFrame, "A prepared photo must replace its tiny preview immediately")

    slot.bind(attachment, frame: frame, maxPixel: 512, kind: .photo)
    slot.seed(try XCTUnwrap(tiny.retained()))
    XCTAssertTrue(slot.hasSharpFrame, "Rebinding the same photo must not replace it with blur")
    XCTAssertNil(slot.loadAction, "Refining visible photo pixels must not show a transfer button")
    slot.close()
    media.close()
    try await h.close()
  }

  func testTinyPreviewKeepsEncodedPixelSizeAndReleasesMemory() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let text = try XCTUnwrap(draft.tinyPreview), data = try XCTUnwrap(Data(base64Encoded: text))
    let encoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
    let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
    XCTAssertLessThanOrEqual(max(width, height), 64)
    var attachment = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: 1,
      durationMs: draft.durationMs, thumbnailKey: draft.id)
    attachment.tinyPreview = text
    let frame: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      _ = media.tinyPreview(attachment) { continuation.resume(with: $0) }
    }
    let image = try XCTUnwrap(frame.image)
    print(
      "KANDINSKY_TINY_PIXELS encoded=\(width)x\(height) decoded=\(image.width)x\(image.height) bytes=\(media.bytesUsed)"
    )
    XCTAssertEqual(
      image.width, width, "A bounded inline preview needs decoding, without an extra resize")
    XCTAssertEqual(
      image.height, height, "GPU presentation already scales the preview to its bubble")
    XCTAssertEqual(media.bytesUsed, image.bytesPerRow * image.height)
    frame.close()
    media.close()
    XCTAssertEqual(media.bytesUsed, 0, "Retiring a preview must release its owned pixels")
    try await h.close()
  }
  func testStagedPreviewSurvivesStorageAndLegacyRetry() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let encoded = try JSONEncoder().encode(draft)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let text = try XCTUnwrap(
      object["tinyPreview"] as? String, "Staging must produce a lightweight inline preview")
    XCTAssertLessThanOrEqual(text.utf8.count, 4096)
    let data = try XCTUnwrap(Data(base64Encoded: text)),
      image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
    XCTAssertLessThanOrEqual(
      (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 999, 64)
    XCTAssertLessThanOrEqual(
      (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 999, 64)
    let command = SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: [draft])
    let first = try await h.repo.send(command),
      attachment = try XCTUnwrap(first.inserted.first?.attachments.first)
    let stored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
    XCTAssertEqual(stored["tinyPreview"] as? String, text)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    media.remoteFile = { _, _, token in
      entered.signal()
      token.onCancel { release.signal() }
      _ = release.wait(timeout: .now() + 5)
      throw MediaError.cancelled
    }
    let slot = MediaImageSlot(store: media)
    slot.bind(attachment, frame: CGRect(x: 0, y: 0, width: 200, height: 140))
    for _ in 0..<100 where !slot.ready { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(slot.ready, "Inline tiny preview must appear while normal thumbnail is blocked")
    XCTAssertLessThan(media.bytesUsed, 9 * 1024 * 1024)
    XCTAssertTrue(slot.loading)
    let layers = try XCTUnwrap(slot.layer.sublayers)
    let play = try XCTUnwrap(layers.dropFirst().first)
    let transfer = try XCTUnwrap(layers.last)
    let playShape = try XCTUnwrap(play.sublayers?.first as? CAShapeLayer)
    let shapes = try XCTUnwrap(transfer.sublayers)
    let ringShape = try XCTUnwrap(shapes.first as? CAShapeLayer)
    let transferShape = try XCTUnwrap(shapes.last as? CAShapeLayer)
    let cancelPath = try XCTUnwrap(transferShape.path)
    let unchanged = slot.layer.frame
    let appearanceReads = try countBackgroundReads(for: slot.layer) {
      for _ in 0..<8 { slot.bind(attachment, frame: unchanged) }
    }
    XCTAssertEqual(appearanceReads, 0, "A ready slot keeps its appearance while its row scrolls")
    let unchangedFrames = try countFrameAssignments(for: slot.layer) {
      slot.bind(attachment, frame: unchanged)
      slot.bind(attachment, frame: unchanged)
    }
    let scrolled = CGRect(x: 0, y: 11.5, width: 200, height: 140)
    let translatedFrames = try countFrameAssignments(for: slot.layer) {
      slot.bind(attachment, frame: scrolled)
    }
    let pathUpdates = try countPathUpdates(for: [playShape, ringShape, transferShape]) {
      slot.bind(attachment, frame: scrolled)
    }
    XCTAssertEqual(unchangedFrames, 0, "Retained photos do not resubmit their unchanged layer frame")
    XCTAssertEqual(translatedFrames, 1, "Moving the slot applies its new layer frame once")
    XCTAssertEqual(slot.layer.frame, scrolled)
    XCTAssertEqual(pathUpdates, 0, "Moving the row should leave all control paths in place")
    let resized = CGRect(x: 0, y: 11.5, width: 180, height: 180)
    slot.bind(attachment, frame: resized, circular: true)
    XCTAssertEqual(slot.layer.frame, resized)
    XCTAssertEqual(slot.layer.cornerRadius, 90)
    XCTAssertTrue(slot.ready)
    slot.bind(attachment, frame: scrolled)
    let point = CGPoint(x: scrolled.midX, y: scrolled.midY)
    XCTAssertEqual(slot.loadAction?.0.midY, point.y)
    XCTAssertTrue(slot.performLoadAction(at: point))
    XCTAssertFalse(slot.loading)
    XCTAssertEqual(slot.loadAction?.1, "Повторить загрузку")
    XCTAssertNotEqual(transferShape.path?.boundingBoxOfPath, cancelPath.boundingBoxOfPath)
    media.remoteFile = nil
    XCTAssertTrue(slot.performLoadAction(at: point))
    for _ in 0..<200 where slot.loading { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(slot.loading)
    XCTAssertNil(slot.loadAction)
    let full = slot.preview()
    XCTAssertGreaterThan(full?.image?.width ?? 0, 64)
    full?.close()
    slot.close()
    release.signal()

    object.removeValue(forKey: "tinyPreview")
    object.removeValue(forKey: "waveform")
    let legacy = try JSONDecoder().decode(
      AttachmentDraft.self, from: JSONSerialization.data(withJSONObject: object))
    var replay = command
    replay.attachments = [legacy]
    let second = try await h.repo.send(replay)
    XCTAssertEqual(
      first.inserted.first?.id, second.inserted.first?.id,
      "Optional preview data cannot change retry identity")
    XCTAssertEqual(
      try h.rawScalar("PRAGMA user_version"), 3, "Old Release must still open the database")
    try await h.close()
  }

  private func countBackgroundReads(for target: CALayer, during action: () -> Void) throws -> Int {
    let selector = #selector(getter: CALayer.backgroundColor)
    let method = try XCTUnwrap(class_getInstanceMethod(CALayer.self, selector))
    let original = method_getImplementation(method)
    typealias GetColor = @convention(c) (CALayer, Selector) -> CGColor?
    let getColor = unsafeBitCast(original, to: GetColor.self)
    var reads = 0
    let measure: @convention(block) (CALayer) -> CGColor? = { layer in
      if layer === target { reads += 1 }
      return getColor(layer, selector)
    }
    let measured = imp_implementationWithBlock(measure)
    method_setImplementation(method, measured)
    defer {
      method_setImplementation(method, original)
      imp_removeBlock(measured)
    }
    action()
    return reads
  }

  private func countFrameAssignments(for target: CALayer, during action: () -> Void) throws -> Int {
    let setter = #selector(setter: CALayer.frame)
    let method = try XCTUnwrap(class_getInstanceMethod(CALayer.self, setter))
    let original = method_getImplementation(method)
    typealias SetFrame = @convention(c) (CALayer, Selector, CGRect) -> Void
    let setFrame = unsafeBitCast(original, to: SetFrame.self)
    var assignments = 0
    let measure: @convention(block) (CALayer, CGRect) -> Void = { layer, frame in
      if layer === target { assignments += 1 }
      setFrame(layer, setter, frame)
    }
    let measured = imp_implementationWithBlock(measure)
    method_setImplementation(method, measured)
    defer {
      method_setImplementation(method, original)
      imp_removeBlock(measured)
    }
    action()
    return assignments
  }

  private func countPathUpdates(for layers: [CAShapeLayer], while move: () -> Void) throws -> Int {
    let setter = #selector(setter: CAShapeLayer.path)
    let method = try XCTUnwrap(class_getInstanceMethod(CAShapeLayer.self, setter))
    let original = method_getImplementation(method)
    typealias SetPath = @convention(c) (CAShapeLayer, Selector, CGPath?) -> Void
    let setPath = unsafeBitCast(original, to: SetPath.self)
    var updates = 0
    let count: @convention(block) (CAShapeLayer, CGPath?) -> Void = { layer, path in
      if layers.contains(where: { $0 === layer }) { updates += 1 }
      setPath(layer, setter, path)
    }
    let measured = imp_implementationWithBlock(count)
    method_setImplementation(method, measured)
    defer {
      method_setImplementation(method, original)
      imp_removeBlock(measured)
    }
    move()
    return updates
  }

}
