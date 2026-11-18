// Замеры чтения маленьких кадров на реальных сохранённых изображениях. Проверяем размеры и
// прозрачность, затем сравниваем время трёх способов подготовки, чтобы более быстрый путь не
// менял ожидаемый рисунок.

import XCTest
import UIKit
import ImageIO
import CryptoKit
import Darwin
@testable import Kandinsky

@MainActor final class TinyPreviewDecodeResearchTests: XCTestCase {
  private struct Input: Decodable {
    let chatId: Int64
    let records: [Record]
  }
  private struct Record: Decodable {
    let assetId: String, blobId: String, tinySHA256: String, tinyPreview: String
  }
  // Проверяем небольшой размер источника и используем прямое чтение либо создание миниатюры. Оба
  // способа получают те же байты для честного сравнения.
  private nonisolated static func decode(_ data: Data, direct: Bool) throws -> CGImage {
    let source = try XCTUnwrap(
      CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
      height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
    guard (1...64).contains(width), (1...64).contains(height) else { throw MediaError.corrupt }
    if direct {
      return try XCTUnwrap(
        CGImageSourceCreateImageAtIndex(
          source, 0,
          [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
            as CFDictionary))
    }
    return try XCTUnwrap(
      CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary))
  }
  // Читаем размеры и сразу выводим кадр в заранее заданный формат изображения. Так можно оценить
  // подготовку к показу целиком, включая работу с цветом.
  private nonisolated static func rasterDecode(_ data: Data) throws -> CGImage {
    let source = try XCTUnwrap(
      CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
      height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
    guard (1...64).contains(width), (1...64).contains(height) else { throw MediaError.corrupt }
    let image = try XCTUnwrap(
      CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    )
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(context.makeImage())
  }
  // Измеряем процессорное время рабочего потока вместе с его системными вызовами. Ожидание
  // запуска в очереди в этот показатель не входит.
  private nonisolated static func cpu() throws -> Double {
    var info = thread_basic_info_data_t(),
      count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { p in
      p.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        thread_info(
          pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { throw MediaError.unavailable }
    return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
      info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }
  // Рисуем изображение в одном цветовом пространстве и копируем четыре канала каждой точки.
  // Сравнение исходных файлов не показало бы, что видит пользователь.
  private nonisolated static func pixels(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(
      UnsafeBufferPointer(
        start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4))
  }
  // Сравниваем чтение настоящих небольших кадров напрямую со штатной миниатюрой. Размеры и
  // прозрачность должны сохраниться.
  func testAlreadySmallRealServerJPEGsAgainstDirectImageDecode() async throws {
    try await compare(raster: false)
  }
  // Проверяем вариант, где фоновый работник готовит кадр к показу за один проход. Для него
  // используем тот же набор файлов и способ сравнения.
  func testAlreadySmallRealServerJPEGsAgainstWorkerRasterDecode() async throws {
    try await compare(raster: true)
  }
  // Проверяем контрольные суммы одиннадцати входов, затем сравниваем размеры и цветовые каналы.
  // По очереди замеряем способы чтения и отдельно убеждаемся, что прозрачность не изменилась.
  private func compare(raster: Bool) async throws {
    let base = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media")
    let input = try JSONDecoder().decode(
      Input.self, from: Data(contentsOf: base.appendingPathComponent("tiny-preview-probe.json")))
    XCTAssertEqual(input.chatId, 1352)
    XCTAssertEqual(input.records.count, 11)
    let inputs = try input.records.map { record -> Data in
      let data = try XCTUnwrap(Data(base64Encoded: record.tinyPreview))
      XCTAssertLessThanOrEqual(data.count, 3072)
      XCTAssertEqual(
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), record.tinySHA256)
      return data
    }
    var comparisons: [[String: Any]] = []
    for (index, data) in inputs.enumerated() {
      let a = try Self.decode(data, direct: false),
        b = try raster ? Self.rasterDecode(data) : Self.decode(data, direct: true)
      XCTAssertEqual(a.width, b.width)
      XCTAssertEqual(a.height, b.height)
      let x = try Self.pixels(a), y = try Self.pixels(b)
      var total = 0, maximum = 0, alpha = 0
      for n in x.indices {
        let difference = abs(Int(x[n]) - Int(y[n]))
        total += difference
        maximum = max(maximum, difference)
        if n % 4 == 3 && difference != 0 { alpha += 1 }
      }
      comparisons.append([
        "assetId": input.records[index].assetId, "blobId": input.records[index].blobId,
        "width": a.width, "height": a.height, "meanRGBAError": Double(total) / Double(x.count),
        "maximumChannelError": maximum, "alphaMismatches": alpha
      ])
    }
    let queue = DispatchQueue(label: "Kandinsky.test.tiny-decode", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          // Читаем выбранным способом и сразу рисуем результат, чтобы не пропустить ленивую
          // обработку. Возвращаем затраты потока, время ожидания и одинаковый объём точек для
          // обеих серий.
          func batch(_ direct: Bool, loops: Int) throws -> [String: Double] {
            let sink = try XCTUnwrap(
              CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let begin = try Self.cpu(), wall = ProcessInfo.processInfo.systemUptime
            var pixelWork = 0
            for _ in 0..<loops {
              for data in inputs {
                try autoreleasepool {
                  let image =
                    try direct && raster
                    ? Self.rasterDecode(data) : Self.decode(data, direct: direct)
                  sink.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                  pixelWork += image.width * image.height
                }
              }
            }
            return [
              "direct": direct ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - wall,
              "pixelWork": Double(pixelWork)
            ]
          }
          _ = try batch(false, loops: 5)
          _ = try batch(true, loops: 5)
          var batches: [[String: Double]] = []
          for direct in [false, true, true, false, false, true, true, false] {
            batches.append(try batch(direct, loops: 80))
          }
          guard Set(batches.compactMap { $0["pixelWork"] }).count == 1 else {
            throw MediaError.corrupt
          }
          reply.resume(returning: batches)
        } catch { reply.resume(throwing: error) }
      }
    }
    let report: [String: Any] = [
      "productionChanged": false,
      "candidate": raster
        ? "direct image forced into worker RGBA bitmap" : "direct image with immediate cache",
      "scope":
        """
        Physical read-only ImageIO capability/cost experiment, exact actual corpus1352 tinyJPEG bytes; no \
        decoder policy or FPS claim
        """,
      "oracle":
        "Independent normalized RGBA, inputSHA, equal forcedpixelwork, native per-thread CPU and ABBAABBA ordering",
      "pixelComparisons": comparisons, "batches": batches
    ]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
    attachment.name = "tiny-preview-imageio-probe"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_TINY_IMAGEIO_PROBE \(String(decoding:bytes,as:UTF8.self))")
    for comparison in comparisons { XCTAssertEqual(comparison["alphaMismatches"] as? Int, 0) }
  }
}
