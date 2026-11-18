// Проверки системного проигрывателя и времени жизни источника видео. Сценарии ловят утечку после
// отмены, потерянное место предпросмотра и ожидание полного файла перед запуском или перемоткой.

import XCTest
import AVFoundation
import CryptoKit
@testable import Kandinsky
private final class RangeReadCount: @unchecked Sendable {
  private let gate = NSLock()
  private var value = 0
  // Увеличиваем счётчик под общей блокировкой. Освобождение источника и чтение диапазона могут
  // прийти из фоновых задач.
  func add() {
    gate.lock()
    value += 1
    gate.unlock()
  }
  var count: Int {
    gate.lock()
    defer { gate.unlock() }
    return value
  }
}
@MainActor final class NativeStreamingTests: XCTestCase {
  // Отменяем подготовку беззвучного ролика и ждём ошибку отмены. Источник должен освободиться
  // ровно один раз даже после дальнейшей уборки.
  func testCancelledSilentPreparationReleasesItsSourceExactlyOnce() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-01.mp4")
    let released = RangeReadCount()
    let source = MediaPlaybackSource(file: fixture) { released.add() }
    let task = Task { try await media.silentVideoAsset(source) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Отменённая подготовка не должна вернуть готовый источник")
    } catch MediaError.cancelled {
    } catch {
      XCTFail("Ожидалась отмена подготовки: \(error)")
    }
    XCTAssertEqual(released.count, 1)
    source.close()
    XCTAssertEqual(released.count, 1)
    media.close()
    try await h.close()
  }

  // Возвращаем ошибку получения видео и ждём завершения предпросмотра. Не должно остаться ни
  // проигрывателя в слое, ни занятого места для другого ролика.
  func testFailedSilentPreviewReleasesItsAdmissionSlot() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-01.mp4")
    let draft = try await media.stageSelection(sourceURL: fixture, mime: "video/mp4")
    let attachment = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey)
    media.remotePlayback = { _, _ in throw MediaError.unavailable }
    let ownersBefore = MediaAdmission.previewOwnerCount
    let changed = expectation(description: "Предпросмотр сообщил об ошибке источника")
    let preview = SilentVideoPreview(store: media)
    preview.onChange = { changed.fulfill() }
    preview.bind(
      attachment, frame: CGRect(x: 0, y: 0, width: 180, height: 120), circular: false,
      cornerRadius: 8, bottomSquare: false)
    await fulfillment(of: [changed], timeout: 2)
    XCTAssertFalse(preview.active)
    XCTAssertNil(preview.layer.player)
    XCTAssertEqual(MediaAdmission.previewOwnerCount, ownersBefore)
    preview.onChange = nil
    preview.close()
    media.close()
    try await h.close()
  }

  // Даём длинное видео по небольшим участкам и проверяем готовность и перемотку до загрузки всего
  // файла. В конце закрываем проигрыватель и сверяем, что активных экземпляров больше нет.
  func testAVPlayerPreparesAndSeeksBeforeEntireMP4Arrives() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission(),
      player = MediaCoordinator(admission: admission, media: media)
    defer {
      player.close()
      media.close()
      admission.close()
    }
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-00.mp4")
    var bytes = try Data(contentsOf: fixture)
    var size = UInt32(4 * 1024 * 1024).bigEndian
    bytes.append(withUnsafeBytes(of: &size) { Data($0) })
    bytes.append(Data("free".utf8))
    bytes.append(Data(repeating: 0, count: 4 * 1024 * 1024 - 8))
    let source = h.root.appendingPathComponent("authored.mp4")
    try bytes.write(to: source)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      length = Int64(bytes.count), counter = RangeReadCount(),
      destination = h.root.appendingPathComponent("media/remote/" + digest + ".mp4")
    let root = h.root
    media.remotePlayback = { _, _ in
      let cache = try MediaRangeCache(
        root: root, blob: digest, length: length, original: destination
      ) { start, end, token in
        if token.isCancelled { throw MediaError.cancelled }
        counter.add()
        Thread.sleep(forTimeInterval: 0.03)
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(start))
        return try file.read(upToCount: Int(end - start + 1)) ?? Data()
      }
      return MediaPlaybackSource(cache: cache, mime: "video/mp4", blob: digest)
    }
    let a = Attachment(
      id: "stream-test", relativePath: "remote/" + digest + ".mp4", mime: "video/mp4",
      byteSize: length, rawWidth: 320, rawHeight: 240, orientation: 1, durationMs: 2000,
      thumbnailKey: "")
    var callsAtReady: Int?, completeAtReady = false
    player.onChange = {
      if player.isReady, callsAtReady == nil {
        callsAtReady = counter.count
        completeAtReady = FileManager.default.fileExists(atPath: destination.path)
        player.pause()
      }
    }
    player.play(target: PlaybackTarget(attachment: a, messageID: 51))
    for _ in 0..<160 {
      if player.isReady || player.lastError != nil { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertNil(player.lastError)
    XCTAssertTrue(player.isReady)
    player.pause()
    let seek = expectation(description: "Seek on partial native asset")
    player.seek(ms: 1200) { done in
      XCTAssertTrue(done)
      seek.fulfill()
    }
    await fulfillment(of: [seek], timeout: 4)
    XCTAssertEqual(player.positionMs, 1200, accuracy: 100)
    XCTAssertLessThan(
      Int64((callsAtReady ?? counter.count) * MediaRangeCache.chunkSize), length,
      "Native playback must not wait for the complete original")
    XCTAssertFalse(completeAtReady)
    player.stop()
    XCTAssertEqual(player.activePlayerCount, 0)
    try await h.close()
  }
}
