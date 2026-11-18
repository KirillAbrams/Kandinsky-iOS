import XCTest
import UIKit
import CryptoKit
import Darwin
@testable import Kandinsky

@MainActor final class TinyPreviewDiskCacheResearchTests: XCTestCase {
  private struct Input: Decodable {
    let chatId: Int64
    let records: [Record]
  }
  private struct Record: Decodable {
    let assetId: String, blobId: String, tinySHA256: String, tinyPreview: String
  }
  private nonisolated static func cpu() throws -> Double {
    var info = thread_basic_info_data_t(),
      count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let result = withUnsafeMutablePointer(to: &info) { p in
      p.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        thread_info(
          pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { throw MediaError.unavailable }
    return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
      info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }
  private nonisolated static func rgba(_ image: CGImage) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
  }
  func testBoundedProductionCacheAgainstUncachedDisplayPreparation() async throws {
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/tiny-preview-probe.json")
    let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: fixture))
    XCTAssertEqual(input.chatId, 1352)
    XCTAssertEqual(input.records.count, 11)
    let inputs = try input.records.map { r -> Data in
      let d = try XCTUnwrap(Data(base64Encoded: r.tinyPreview))
      XCTAssertEqual(SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined(), r.tinySHA256)
      return d
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tiny-disk-probe-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
    let queue = DispatchQueue(label: "Kandinsky.test.tiny-disk", qos: .userInitiated)
    let report: Data = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          let coldBegin = try Self.cpu(), coldWall = ProcessInfo.processInfo.systemUptime
          for data in inputs {
            _ = try TinyPreviewDiskCache.image(data, root: root)
          }
          let coldCPU = try Self.cpu() - coldBegin,
            coldSeconds = ProcessInfo.processInfo.systemUptime - coldWall
          var comparisons: [[String: Any]] = []
          for (index, data) in inputs.enumerated() {
            let reference = try TinyPreviewDiskCache.prepare(data)
            let cached = try TinyPreviewDiskCache.image(data, root: root)
            let actual = try Self.rgba(cached), expected = try Self.rgba(reference)
            guard actual == expected, reference.width == cached.width,
              reference.height == cached.height
            else { throw MediaError.corrupt }
            comparisons.append([
              "assetId": input.records[index].assetId, "blobId": input.records[index].blobId,
              "width": reference.width, "height": reference.height,
              "rgbaSHA256": SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined(),
              "pixelIdentical": true
            ])
          }
          func batch(_ raw: Bool, loops: Int) throws -> [String: Double] {
            let sink = try XCTUnwrap(
              CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let start = try Self.cpu(), wall = ProcessInfo.processInfo.systemUptime
            var work = 0
            for _ in 0..<loops {
              for data in inputs {
                try autoreleasepool {
                  let image =
                    try raw
                    ? TinyPreviewDiskCache.image(data, root: root)
                    : TinyPreviewDiskCache.prepare(data)
                  sink.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                  work += image.width * image.height
                }
              }
            }
            return [
              "rawDisk": raw ? 1 : 0, "threadCPUSeconds": try Self.cpu() - start,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - wall, "pixelWork": Double(work)
            ]
          }
          _ = try batch(false, loops: 5)
          _ = try batch(true, loops: 5)
          var batches: [[String: Double]] = []
          for raw in [false, true, true, false, false, true, true, false] {
            batches.append(try batch(raw, loops: 80))
          }
          guard Set(batches.compactMap { $0["pixelWork"] }).count == 1 else {
            throw MediaError.corrupt
          }
          let files = try XCTUnwrap(
            FileManager.default.enumerator(
              at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
          ).allObjects.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
          }
          let bytes = try files.reduce(0) {
            try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
          }
          func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
          }
          let ratio =
            median(batches.filter { $0["rawDisk"] == 1 }.map { $0["threadCPUSeconds"]! })
            / median(batches.filter { $0["rawDisk"] == 0 }.map { $0["threadCPUSeconds"]! })
          guard ratio <= 0.55 else { throw MediaError.unavailable }
          let value: [String: Any] = [
            "productionCacheUnderTest": true,
            "candidate": "Production 4000-bucket cache of display-ready pixels",
            "oracle":
              "Exact11realcorpus1352 inputSHA; fullnormalizedpixels; nativeper-threadCPU ABBAABBA equalforcedpixelwork",
            "coldFirstDecodeWriteCPUSeconds": coldCPU,
            "coldFirstDecodeWriteWallSeconds": coldSeconds, "fileCount": files.count,
            "fileBytes": bytes, "pixelComparisons": comparisons, "batches": batches,
            "medianCandidateReferenceRatio": ratio
          ]
          reply.resume(
            returning: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        } catch { reply.resume(throwing: error) }
      }
    }
    let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
    attachment.name = "tiny-preview-disk-probe"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_TINY_DISK_PROBE \(String(decoding:report,as:UTF8.self))")
  }
}
