// Проверяет чтение частей видео, повторное открытие и сборку целого файла на временном диске.
// Сверяет байты с известным исходником.

import XCTest
import CryptoKit
@testable import Kandinsky
final class MediaRangeCacheTests: XCTestCase {
  // Читает конец файла, закрывает источник и снова читает тот же конец без сети. Затем получает
  // остальные части и сравнивает готовый файл. Закрытый источник не должен принять новое чтение.
  func testSeekDiskReuseAndVerifiedPromotion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data((0..<MediaRangeCache.chunkSize * 3 + 17).map { UInt8($0 % 251) }),
      blob = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      original = root.appendingPathComponent("media/remote/" + blob + ".mp4")
    var calls = 0
    let first = try MediaRangeCache(
      root: root, blob: blob, length: Int64(bytes.count), original: original
    ) { start, end, _ in
      calls += 1
      return bytes.subdata(in: Int(start)..<Int(end + 1))
    }
    let tail = try first.read(
      offset: Int64(bytes.count - 10), count: 10, cancellation: MediaCancellation())
    XCTAssertEqual(tail, bytes.suffix(10))
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    first.close()
    let resumed = try MediaRangeCache(
      root: root, blob: blob, length: Int64(bytes.count), original: original
    ) { start, end, _ in
      calls += 1
      return bytes.subdata(in: Int(start)..<Int(end + 1))
    }
    XCTAssertEqual(
      try resumed.read(
        offset: Int64(bytes.count - 10), count: 10, cancellation: MediaCancellation()), tail)
    XCTAssertEqual(calls, 1, "A reopened partial must work from disk")
    for chunk in 0..<3 {
      _ = try resumed.read(
        offset: Int64(chunk * MediaRangeCache.chunkSize), count: 1,
        cancellation: MediaCancellation())
    }
    XCTAssertEqual(calls, 4)
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    resumed.close()
    XCTAssertThrowsError(try resumed.read(offset: 0, count: 1, cancellation: MediaCancellation()))
  }
  // Возвращает слишком короткую часть и ждёт отказа. Файл части не должен появиться, иначе
  // следующее открытие могло бы принять обрыв за готовые данные.
  func testShortRangeIsNotCommitted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MediaRangeCache(
      root: root, blob: String(repeating: "a", count: 64), length: 1024,
      original: root.appendingPathComponent("original")
    ) { _, _, _ in Data(repeating: 1, count: 10) }
    XCTAssertThrowsError(try cache.read(offset: 0, count: 1, cancellation: MediaCancellation()))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "media/ranges/" + String(repeating: "a", count: 64) + "/0.chunk"
        ).path))
    cache.close()
  }
}
