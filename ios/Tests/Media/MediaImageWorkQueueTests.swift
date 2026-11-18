import XCTest
import ImageIO
@testable import Kandinsky

@MainActor final class MediaImageWorkQueueTests: XCTestCase {
  func testLastSubscriberCancellationStopsSharedWorkBeforeMainQueueRuns() async {
    let requests = MediaThumbnailRequests(), inner = MediaCancellation()
    let retired = expectation(description: "every subscriber completes once")
    retired.expectedFulfillmentCount = 3
    var starts = 0
    let start: MediaThumbnailRequests.Start = { _, _, _, _ in
      starts += 1
      return starts == 1 ? inner : MediaCancellation()
    }
    let complete: (Result<PreparedImage, Error>) -> Void = { result in
      if case let .success(frame) = result { frame.close(); XCTFail("Cancelled work published") }
      retired.fulfill()
    }
    let a = requests.submit(key: "shared", priority: 0, progress: { _ in }, start: start, completion: complete)
    let b = requests.submit(key: "shared", priority: 1, progress: { _ in }, start: start, completion: complete)
    let finished = DispatchSemaphore(value: 0)
    var stoppedAfterFirst = true, stoppedAfterLast = false
    DispatchQueue.global().async {
      a.cancel(); stoppedAfterFirst = inner.isCancelled
      b.cancel(); stoppedAfterLast = inner.isCancelled
      finished.signal()
    }
    XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(stoppedAfterFirst, "The other owner still needs the transfer")
    XCTAssertTrue(stoppedAfterLast, "Cancellation cannot wait behind a queued decoded result")
    let replacement = requests.submit(key: "shared", priority: 1, progress: { _ in },
      start: start, completion: complete)
    XCTAssertEqual(starts, 2, "A new subscriber must not join an already cancelled generation")
    replacement.cancel()
    await fulfillment(of: [retired], timeout: 1)
    requests.clear()
  }

  private enum Phase { case lookup, download, decode }

  func testCancellationDuringLookupDoesNotAdmitPixels() async throws {
    try await checkRetirement(at: .lookup, closeQueue: false)
  }

  func testClosingDuringDownloadCancelsTheFetchAndNeverDecodes() async throws {
    try await checkRetirement(at: .download, closeQueue: true)
  }

  func testLateDecodeAfterCancellationReleasesItsCharge() async throws {
    try await checkRetirement(at: .decode, closeQueue: false)
  }

  private func checkRetirement(at phase: Phase, closeQueue: Bool) async throws {
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as? [String: Any])
    let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
    let name = try XCTUnwrap(files.first { ($0["mime"] as? String) == "image/jpeg" }?["fileName"] as? String)
    let source = fixtures.appendingPathComponent("media/" + name)
    let queue = MediaImageWorkQueue(), fetch = MediaCancellation(), budget = ImageByteBudget()
    let started = expectation(description: "Selected stage reached")
    let finished = expectation(description: "Exactly one cancelled completion")
    finished.assertForOverFulfill = true
    let release = DispatchSemaphore(value: 0)
    var admissions = 0
    func hold() throws {
      started.fulfill()
      guard release.wait(timeout: .now() + 3) == .success else { throw MediaError.interrupted }
    }
    fetch.onCancel { release.signal() }
    let request = queue.submit(
      priority: 1, fetch: fetch,
      local: { _ in
        if phase == .lookup { try hold() }
        return phase == .download ? nil : (source, "image/jpeg")
      },
      remote: { _ in
        XCTAssertEqual(phase, .download)
        try hold()
        return (source, "image/jpeg")
      },
      admit: {
        admissions += 1
        return try XCTUnwrap(budget.reserve(128 * 128 * 8 + 4096))
      },
      decode: { file, charge in
        XCTAssertEqual(phase, .decode)
        try hold()
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(file.0 as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(encoded, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 128,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary))
        try charge.shrink(to: image.bytesPerRow * image.height)
        return ImagePixels(image: image, charge: charge)
      },
      completion: { result in
        if case let .success(pixels) = result { pixels.closeOwner(); XCTFail("Retired request published") }
        if case let .failure(error) = result { XCTAssertEqual(error as? MediaError, .cancelled) }
        finished.fulfill()
      })
    defer { release.signal(); request.cancel(); queue.close() }
    await fulfillment(of: [started], timeout: 2)
    if closeQueue { queue.close() } else { request.cancel() }
    await fulfillment(of: [finished], timeout: 3)
    XCTAssertTrue(fetch.isCancelled)
    XCTAssertEqual(admissions, phase == .decode ? 1 : 0)
    XCTAssertEqual(budget.bytes, 0)
  }
}
