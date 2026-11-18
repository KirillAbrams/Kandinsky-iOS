import XCTest
import AVFoundation
import CryptoKit
@testable import Kandinsky

@MainActor final class NetworkPlaybackTests: XCTestCase {
  private func history(_ api: NetworkAPI, _ profile: NetworkProfile, _ h: RepositoryHarness)
    async throws -> [Message]
  {
    let (chat, data) = try await StudioTestServer.recentMedia(api)
    let cache = NetworkStore(userID: profile.userId)
    return try await h.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT OR IGNORE INTO chats(id,title) VALUES(?,'Public media')", [.integer(chat)])
      return try cache.history(db, chat: chat, data: data).flatMap(\.updated)
    }
  }
  private func result(_ number: Int, kind: MessageKind, in rows: [Message]) throws -> Message {
    let sorted = rows.sorted { $0.order < $1.order }
    let prompt = try XCTUnwrap(sorted.firstIndex { $0.text == "Медиа \(number)" })
    let index = sorted.index(after: prompt)
    let result = try XCTUnwrap(sorted.indices.contains(index) ? sorted[index] : nil)
    XCTAssertEqual(result.kind, kind)
    return result
  }

  func testOriginalVideosShowMovingFramesAndReuseRangeCache() async throws {
    let profile = try StudioTestServer.profile(), h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let requests = NetworkRequestTally(),
      api = NetworkAPI(
        profile: profile, onRequestFinished: { requests.increment() },
        rangeObserved: { blob, start, end, bytes, cancelled in
          requests.range(blob: blob, start: start, end: end, bytes: bytes, cancelled: cancelled)
        })
    let rows = try await history(api, profile, h)
    let selected = try [190, 187].map { try result($0, kind: .video, in: rows) }
    let remote = NetworkMedia(store: h.store, api: api)
    media.remotePlayback = { try remote.playback($0, token: $1) }
    media.remoteFile = { try remote.resolve($0, preview: $1, token: $2) }
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      media.close()
      api.close()
      window.isHidden = true
      previous?.makeKey()
    }
    var positions: [[Int64]] = []
    func cacheFiles() -> [String: Int] {
      let base = h.root.appendingPathComponent("media"), fm = FileManager.default
      guard
        let files = fm.enumerator(
          at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
      else { return [:] }
      var result: [String: Int] = [:]
      for case let file as URL in files {
        if let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          value.isRegularFile == true
        {
          result[String(file.path.dropFirst(base.path.count + 1))] = value.fileSize ?? 0
        }
      }
      return result
    }
    func exercise() async throws -> [Int] {
      let owners = selected.map { _ in SilentVideoPreview(store: media) }
      defer { owners.forEach { $0.close() } }
      for (n, owner) in owners.enumerated() {
        root.view.layer.addSublayer(owner.layer)
        owner.bind(
          try XCTUnwrap(selected[n].attachments.first),
          frame: CGRect(x: 10 + n * 180, y: 100, width: 170, height: 170), circular: false,
          cornerRadius: 12, bottomSquare: false)
      }
      let until = Date().addingTimeInterval(35)
      while Date() < until && !owners.allSatisfy({ $0.active }) {
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      XCTAssertTrue(owners.allSatisfy { $0.active }, "Оба видео должны воспроизводиться")
      let players = try owners.map { try XCTUnwrap($0.layer.player) },
        items = try players.map { try XCTUnwrap($0.currentItem) }
      XCTAssertTrue(players.allSatisfy { $0.isMuted })
      let outputs = items.map { item in
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(out)
        return out
      }
      defer { for n in items.indices { items[n].remove(outputs[n]) } }
      var hashes = [Set<String>(), Set<String>()]
      let end = Date().addingTimeInterval(4)
      while Date() < end && hashes.contains(where: { $0.count < 3 }) {
        for n in outputs.indices {
          if let pixels = outputs[n].copyPixelBuffer(
            forItemTime: players[n].currentTime(), itemTimeForDisplay: nil)
          {
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let address = CVPixelBufferGetBaseAddress(pixels) {
              let bytes = Data(
                bytes: address,
                count: CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
              hashes[n].insert(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
          }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
      }
      for values in hashes {
        XCTAssertGreaterThanOrEqual(values.count, 3, "Remote source pixels must actually change")
      }
      positions.append(players.map { Int64($0.currentTime().seconds * 1000) })
      owners.forEach { $0.close() }
      XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
      return hashes.map(\.count)
    }
    let before = requests.count
    let coldFrames = try await exercise()
    try await Task.sleep(nanoseconds: 100_000_000)
    let cold = requests.count, filesCold = cacheFiles(), rangeBoundary = requests.ranges.count
    let partialFrames = try await exercise()
    try await Task.sleep(nanoseconds: 100_000_000)
    let partialRequests = requests.count - cold,
      partialReads = Array(requests.ranges.dropFirst(rangeBoundary))
    let repeatedCached = partialReads.filter { event in
      guard let blob = event["blob"] as? String, let start = event["start"] as? Int64 else {
        return false
      }
      return filesCold[
        "ranges/" + blob + "/" + String(start / Int64(MediaRangeCache.chunkSize)) + ".chunk"] != nil
    }
    XCTAssertTrue(
      repeatedCached.isEmpty,
      "Partial playback must not issue HTTP for chunks already complete on disk")
    for row in selected { _ = try await media.ensureOriginal(try XCTUnwrap(row.attachments.first)) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let fullBoundary = requests.count, fullRangeBoundary = requests.ranges.count
    let fullFrames = try await exercise()
    try await Task.sleep(nanoseconds: 100_000_000)
    let fullWarm = requests.count - fullBoundary
    XCTAssertEqual(fullWarm, 0, "A fully cached original must reopen without HTTP")
    XCTAssertEqual(
      requests.ranges.count, fullRangeBoundary,
      "A fully cached original must not enter the HTTP range reader")
    let report: [String: Any] = [
      "source": "real HTTPS range cache", "coldRequests": cold - before, "setupRequests": before,
      "partialWarmRequests": partialRequests,
      "partialWarmCachedRangeRequests": repeatedCached.count, "fullOriginalWarmRequests": fullWarm,
      "coldUniqueNativeFrames": coldFrames, "partialWarmUniqueNativeFrames": partialFrames,
      "fullWarmUniqueNativeFrames": fullFrames, "positionsMs": positions,
      "filesAfterCold": filesCold, "filesAfterWarm": cacheFiles(),
      "requestCompletionUptimes": requests.times, "rangeReads": requests.ranges
    ]
    let attachment = XCTAttachment(
      data: try JSONSerialization.data(withJSONObject: report), uniformTypeIdentifier: "public.json"
    )
    attachment.name = "Воспроизведение и повторное открытие"
    attachment.lifetime = .keepAlways
    add(attachment)
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  func testRealServerCatalogueUsesVerifiedOriginalsAndWarmCacheMakesNoRequests() async throws {
    let profile = try StudioTestServer.profile(), h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let requests = NetworkRequestTally()
    let api = NetworkAPI(profile: profile, onRequestFinished: { requests.increment() })
    defer {
      api.close()
      media.close()
    }
    let rows = try await history(api, profile, h)
    let remote = NetworkMedia(store: h.store, api: api)
    media.remoteFile = { try remote.resolve($0, preview: $1, token: $2) }
    let originals: [(Int, MessageKind, String)] = [
      (191, .photo, "4848418b74eba9be7365d2f153d01ce165a2e0dc1144c67472dcb752133eb8a5"),
      (190, .video, "eea028acffe3fe7d9719d1f3af21f2b5e1dc7344858bff54d55e893e566d250a")
    ]
    var verified: [Attachment] = []
    for (number, kind, checksum) in originals {
      let row = try result(number, kind: kind, in: rows)
      let attachment = try XCTUnwrap(row.attachments.first)
      let file = try await media.ensureOriginal(attachment)
      let digest = SHA256.hash(data: try Data(contentsOf: file))
      XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), checksum)
      verified.append(attachment)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let cold = requests.count
    XCTAssertGreaterThanOrEqual(cold, verified.count)
    for attachment in verified { _ = try await media.ensureOriginal(attachment) }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(requests.count, cold)
    media.close()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  func testDownloadedMP4WithOpaqueFilenameReachesNativePlayer() async throws {
    let h = try await RepositoryHarness.open()
    let root = h.root.appendingPathComponent("media/remote")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-00.mp4")
    let destination = root.appendingPathComponent("0123456789abcdef0123456789abcdef")
    try FileManager.default.copyItem(at: fixture, to: destination)
    let media = MediaStore(store: h.store), admission = MediaAdmission()
    let api = NetworkAPI(profile: nil)
    let remote = NetworkMedia(store: h.store, api: api)
    media.remoteFile = { try remote.resolve($0, preview: $1, token: $2) }
    let player = MediaCoordinator(admission: admission, media: media)
    defer {
      api.close()
      player.close()
      media.close()
      admission.close()
    }
    let attachment = Attachment(
      id: "opaque-video", relativePath: "remote/" + destination.lastPathComponent,
      mime: "video/mp4", byteSize: 77475, rawWidth: 320, rawHeight: 240, orientation: 1,
      durationMs: 2000, thumbnailKey: "")
    player.play(target: PlaybackTarget(attachment: attachment, messageID: 1))
    for _ in 0..<100 {
      if player.isReady || player.lastError != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(player.lastError, "\(String(describing:player.lastError))")
    XCTAssertTrue(player.isReady, "Downloaded media must open in the actual AVPlayer")
    player.close()
    try await h.close()
  }
}

private final class NetworkRequestTally: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double] = []
  private var rangeValues: [[String: Any]] = []
  func range(blob: String, start: Int64, end: Int64, bytes: Int, cancelled: Bool) {
    lock.lock()
    rangeValues.append([
      "blob": blob, "start": start, "end": end, "bytes": bytes, "cancelled": cancelled,
      "uptime": ProcessInfo.processInfo.systemUptime
    ])
    lock.unlock()
  }
  var ranges: [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return rangeValues
  }
  func increment() {
    lock.lock()
    values.append(ProcessInfo.processInfo.systemUptime)
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
  var times: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
