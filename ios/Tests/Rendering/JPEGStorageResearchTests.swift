// Проверяем, как хранение уменьшенной фотографии влияет на цвет, прозрачность и время подготовки
// при одинаковом исходном файле.

import XCTest
import UIKit
import ImageIO
import Darwin
@testable import Kandinsky

@MainActor final class JPEGStorageResearchTests: XCTestCase {
  private struct Catalogue: Decodable { let files: [Record] }
  private struct Record: Decodable { let fileName: String, mime: String, blobId: String }
  // Читаем уменьшенное изображение с ограничением размера. По признаку возвращаем готовую
  // картинку напрямую либо перекладываем её пиксели в отдельную область памяти.
  private nonisolated static func prepare(_ url: URL, copy: Bool) throws -> CGImage {
    let source = try XCTUnwrap(
      CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    let image = try XCTUnwrap(
      CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary))
    guard copy else { return image }
    let c = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return try XCTUnwrap(c.makeImage())
  }
  // Читаем суммарное время текущего потока с точностью до долей секунды. Так паузы между
  // повторениями не занижают и не завышают затраты на подготовку.
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
    guard result == KERN_SUCCESS else {
      throw NSError(domain: "NativeThreadCPU", code: Int(result))
    }
    return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
      info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }
  // Рисуем результат в общий цветовой формат и копируем байты. Это нужно, чтобы одинаково читать
  // прозрачность обеих картинок.
  private func pixels(_ image: CGImage) throws -> [UInt8] {
    let c = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(
      UnsafeBufferPointer(
        start: try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
  }
  // На восьми исходных файлах сверяем размеры и содержимое. В обоих вариантах большая сторона
  // остаётся в пределах 512 пикселей, а сравнение вылавливает изменение цветов.
  func testNativeImageStorageWithoutChangingThumbnailDecoder() async throws {
    let base = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media")
    let files = try JSONDecoder().decode(
      Catalogue.self, from: Data(contentsOf: base.appendingPathComponent("manifest.json"))
    ).files.filter { $0.mime == "image/jpeg" }
    XCTAssertEqual(files.count, 8)
    let inputs = files.map { base.appendingPathComponent($0.fileName) }
    var quality: [[String: Any]] = []
    for (index, file) in inputs.enumerated() {
      let a = try Self.prepare(file, copy: true), b = try Self.prepare(file, copy: false)
      XCTAssertEqual(a.width, b.width)
      XCTAssertEqual(a.height, b.height)
      XCTAssertLessThanOrEqual(max(b.width, b.height), 512)
      let p = try pixels(a), q = try pixels(b)
      var error: Double = 0, maximum = 0, alpha = 0
      for n in p.indices {
        let d = abs(Int(p[n]) - Int(q[n]))
        error += Double(d)
        maximum = max(maximum, d)
        if n % 4 == 3 && d != 0 { alpha += 1 }
      }
      quality.append([
        "blobId": files[index].blobId, "width": b.width, "height": b.height,
        "nativeBitsPerPixel": b.bitsPerPixel, "nativeBitmapInfo": b.bitmapInfo.rawValue,
        "nativeSpace": b.colorSpace?.name as String? ?? "unknown",
        "meanRGBAError": error / Double(p.count), "maximumChannelError": maximum,
        "alphaMismatchPixels": alpha
      ])
    }
    let queue = DispatchQueue(label: "Kandinsky.test.jpeg-storage", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          // Многократно готовим уменьшенные фото одним способом и возвращаем время и площадь.
          // Если площади отличаются, результат замера нельзя сравнить.
          func batch(_ copy: Bool) throws -> [String: Double] {
            let cpuStart = try Self.cpu(), start = ProcessInfo.processInfo.systemUptime
            var work = 0
            for _ in 0..<30 {
              for input in inputs {
                try autoreleasepool {
                  let image = try Self.prepare(input, copy: copy)
                  work += image.width * image.height
                }
              }
            }
            return [
              "copy": copy ? 1 : 0, "threadCPUSeconds": try Self.cpu() - cpuStart,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - start,
              "pixelWork": Double(work)
            ]
          }
          _ = try batch(true)
          _ = try batch(false)
          var result: [[String: Double]] = []
          for copy in [true, false, false, true, true, false, false, true] {
            result.append(try batch(copy))
          }
          guard Set(result.compactMap { $0["pixelWork"] }).count == 1 else {
            throw NSError(domain: "UnequalDecodeWork", code: 1)
          }
          reply.resume(returning: result)
        } catch { reply.resume(throwing: error) }
      }
    }
    let report: [String: Any] = [
      "scope":
        "Read-only physical JPEG storage experiment, no app/decoder policy change; not Release/FPS acceptance",
      "productionChanged": false, "source": "Eight verified real server corpus1352 photo originals",
      "pixelComparisons": quality, "thirtyLoopsPerBatch": true, "alternatingABBAABBA": batches
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    a.name = "jpeg-storage-native-benchmark"
    a.lifetime = .keepAlways
    add(a)
    print("KANDINSKY_JPEG_STORAGE_BENCHMARK \(String(decoding:data,as:UTF8.self))")
    for comparison in quality {
      XCTAssertLessThan(
        comparison["meanRGBAError"] as! Double, 0.35,
        "Removing an eager copy must preserve visible color/edges")
      XCTAssertEqual(comparison["alphaMismatchPixels"] as! Int, 0)
    }
  }
}
