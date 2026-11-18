// Сравниваем два способа хранения нарисованного сообщения в памяти. Проверяем совпадение букв,
// края и цвета и отдельно замеряем затраты на рисование.

import XCTest
import UIKit
import Darwin
@testable import Kandinsky

@MainActor final class RasterFormatResearchTests: XCTestCase {
  // Выделяем картинку под один фрагмент с заданным порядком байтов и выравниванием строк. Рисуем
  // туда один и тот же подготовленный текст, чтобы изолировать различия формата.
  private nonisolated static func raster(
    _ prepared: PreparedText, _ info: UInt32, _ rowAlignment: Int
  ) throws -> CGImage {
    let width = Int(ceil(prepared.width * 3)), height = Int(ceil(prepared.blocks[0].height * 3))
    let stride = rowAlignment == 0 ? 0 : (width * 4 + rowAlignment - 1) & ~(rowAlignment - 1)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 3, y: -3)
    prepared.draw(part: 0, in: context)
    return try XCTUnwrap(context.makeImage())
  }
  // Узнаём формат системного рисунка и проверяем его на настоящих сообщениях. Смена порядка
  // хранения пикселей не должна ухудшить очертания букв или углов.
  func testCompareStandardDeviceBitmapFormatForActualMessageRasters() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    format.preferredRange = .standard
    var native: UInt32 = 0, alignment = 0
    _ = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image {
      context in
      native = context.cgContext.bitmapInfo.rawValue
      alignment = context.cgContext.bytesPerRow
    }
    let original = CGImageAlphaInfo.premultipliedLast.rawValue
    XCTAssertNotEqual(native, 0)
    XCTAssertTrue([32, 64].contains(alignment))
    let payloads = [
      "Короткое сообщение 👋",
      String(repeating: "Привет é 👨‍👩‍👧‍👦 مرحبا — настоящее сообщение. ", count: 30),
      "Подпись к фотографии. Привет 👋 مرحبا"
    ]
    let resources = payloads.enumerated().map { index, text -> PreparedText in
      let attachment = Attachment(
        id: "raster-reference", relativePath: "reference/photo.jpg", mime: "image/jpeg",
        byteSize: 100, rawWidth: 640, rawHeight: 480, orientation: 1, durationMs: 0,
        thumbnailKey: "raster-reference")
      let row = Message(
        id: Int64(index + 1), chatID: 4,
        order: OrderKey(sortKey: Int64(index + 1), messageID: Int64(index + 1)),
        direction: index.isMultiple(of: 2) ? .incoming : .outgoing, savedAtMs: 0,
        kind: index == 2 ? .photo : .text, text: index == 2 ? "" : text,
        caption: index == 2 ? text : "", replyToID: nil, revision: 1,
        attachments: index == 2 ? [attachment] : [])
      return PreparedText(
        message: row,
        key: TextLayoutKey(
          messageID: row.id, revision: 1, width: index == 2 ? 304 : 280, fontSize: 18, scale: 3))
    }
    defer { resources.forEach { $0.close() } }
    // Приводим рисунок к четырём одинаково расположенным составляющим пикселя. Иначе различие
    // порядка байтов выглядело бы как различие цвета.
    func pixels(_ image: CGImage) throws -> [UInt8] {
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
    for prepared in resources {
      let before = try pixels(Self.raster(prepared, original, 0)),
        after = try pixels(Self.raster(prepared, native, alignment))
      let error =
        zip(before, after).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
        / Double(before.count)
      print(
        """
        KANDINSKY_BITMAP_FORMAT_PIXELS id=\(prepared.key.messageID) original=\(original) native=\(native) \
        alignment=\(alignment) mean=\(error)
        """
      )
      XCTAssertLessThan(
        error, 0.35, "Format research must not trade glyph/alpha/color quality for CPU")
    }
    let worker = DispatchQueue(label: "Kandinsky.test.raster-format", qos: .userInitiated),
      selected = native, rowAlignment = alignment
    let measurements: [[String: Double]] = try await withCheckedThrowingContinuation {
      continuation in
      worker.async {
        do {
          // Получаем время работы текущего потока в секундах. Отдельный замер потока уменьшает
          // влияние соседних работ.
          func cpu() throws -> Double {
            var info = thread_basic_info_data_t(),
              count = mach_msg_type_number_t(
                MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let capacity = Int(count)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
              pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                thread_info(
                  pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0,
                  &count)
              }
            }
            guard result == KERN_SUCCESS else {
              throw NSError(domain: "NativeThreadCPU", code: Int(result))
            }
            return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
              info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
          }
          // Повторяем рисование одной подборки с выбранным форматом и выравниванием. Возвращаем
          // время и суммарную площадь, чтобы заметить разный объём работы.
          func batch(_ bitmapInfo: UInt32, _ rowAlignment: Int) throws -> [String: Double] {
            let start = ProcessInfo.processInfo.systemUptime, cpuStart = try cpu()
            var digest = 0
            for _ in 0..<100 {
              for prepared in resources {
                try autoreleasepool {
                  let image = try Self.raster(prepared, bitmapInfo, rowAlignment)
                  digest += image.width * image.height + image.bitsPerPixel
                }
              }
            }
            return [
              "wallSeconds": ProcessInfo.processInfo.systemUptime - start,
              "threadCPUSeconds": try cpu() - cpuStart, "digest": Double(digest)
            ]
          }
          _ = try batch(original, 0)
          _ = try batch(selected, rowAlignment)
          var result: [[String: Double]] = []
          for pair in 0..<3 {
            let a: [String: Double], b: [String: Double]
            if pair.isMultiple(of: 2) {
              a = try batch(original, 0)
              b = try batch(selected, rowAlignment)
            } else {
              b = try batch(selected, rowAlignment)
              a = try batch(original, 0)
            }
            guard a["digest"] == b["digest"] else {
              throw NSError(domain: "UnequalRasterWork", code: 1)
            }
            result.append([
              "pair": Double(pair), "originalCPUSeconds": a["threadCPUSeconds"]!,
              "nativeCPUSeconds": b["threadCPUSeconds"]!, "originalWallSeconds": a["wallSeconds"]!,
              "nativeWallSeconds": b["wallSeconds"]!, "digest": a["digest"]!
            ])
          }
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "originalBitmapInfo": original, "nativeBitmapInfo": native, "nativeAlignment": alignment,
        "threeHundredRastersPerBatch": true, "alternatingPairs": measurements
      ], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "bitmap-format-native-benchmark"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_BITMAP_FORMAT_BENCHMARK \(String(decoding:data,as:UTF8.self))")
  }
}
