import XCTest
import UIKit
import Darwin
@testable import Kandinsky

@MainActor final class BubbleBackgroundResearchTests: XCTestCase {
  private struct Input: Decodable {
    let chatId: Int64
    let rows: [Row]
  }
  private struct Row: Decodable {
    let messageId: Int64, sortKey: Int64, savedAtMs: Int64
    let text: String, direction: String
  }
  private struct Geometry: Sendable {
    let width: CGFloat, height: CGFloat, offset: CGFloat, blockHeight: CGFloat
  }
  private final class Outline: @unchecked Sendable {
    let radius: CGFloat, color: CGColor
    init(radius: CGFloat, scale: CGFloat, color: CGColor) throws {
      self.radius = radius
      self.color = color
    }
    /// Смещает полный прямоугольник по вертикали, чтобы получить нужный фрагмент длинного сообщения.
    func draw(_ geometry: Geometry, in c: CGContext) {
      MessageBubbleBackground.fill(
        CGRect(x: 0, y: -geometry.offset, width: geometry.width, height: geometry.height),
        radius: radius, color: color, in: c)
    }
  }
  private nonisolated static func raster(
    _ geometry: Geometry, radius: CGFloat, scale: CGFloat, color: CGColor, outline: Outline?
  ) throws -> CGImage {
    let w = Int(ceil(geometry.width * scale)), h = Int(ceil(geometry.blockHeight * scale))
    let c = try XCTUnwrap(
      CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: 0, y: CGFloat(h))
    c.scaleBy(x: scale, y: -scale)
    if let outline {
      outline.draw(geometry, in: c)
    } else {
      c.setFillColor(color)
      c.addPath(
        CGPath(
          roundedRect: CGRect(
            x: 0, y: -geometry.offset, width: geometry.width, height: geometry.height),
          cornerWidth: radius, cornerHeight: radius, transform: nil))
      c.fillPath()
    }
    return try XCTUnwrap(c.makeImage())
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
    guard result == KERN_SUCCESS else {
      throw NSError(domain: "NativeThreadCPU", code: Int(result))
    }
    return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
      info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }
  private nonisolated static func pixels(_ image: CGImage) throws -> [UInt8] {
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
  private nonisolated static func plainRaster(
    _ prepared: PreparedText, product: Bool, scale: CGFloat, translation: CGFloat = 0
  ) throws -> CGImage {
    let b = prepared.blocks[0], w = Int(ceil(prepared.width * scale + 2)),
      h = Int(ceil(b.height * scale + 2))
    let c = try XCTUnwrap(
      CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: translation, y: CGFloat(h) + translation)
    c.scaleBy(x: scale, y: -scale)
    if product {
      prepared.draw(part: 0, in: c)
    } else {
      c.setFillColor(
        (prepared.message.direction == .outgoing ? KandinskyPalette.outgoing : UIColor.white)
          .cgColor)
      c.addPath(
        CGPath(
          roundedRect: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height),
          cornerWidth: 14, cornerHeight: 14, transform: nil))
      c.fillPath()
    }
    return try XCTUnwrap(c.makeImage())
  }
  func testBackgroundFallbackAndGraphicsStateMatchOriginalPath() throws {
    let rectangles = [
      CGRect(x: 0, y: 0, width: 280, height: 72),
      CGRect(x: 0.25, y: 0.5, width: 280.25, height: 72.3),
      CGRect(x: 0, y: 0, width: 13, height: 11)
    ]
    var comparisons = 0
    for rect in rectangles {
      for scale: CGFloat in [1, 2, 3] {
        for rotation: CGFloat in [0, 0.17] {
          for color in [
            UIColor.white.cgColor, KandinskyPalette.outgoing.cgColor,
            UIColor.white.withAlphaComponent(0.4).cgColor
          ] {
            try autoreleasepool {
              func draw(_ product: Bool) throws -> CGImage {
                let c = try XCTUnwrap(
                  CGContext(
                    data: nil, width: 900, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                c.translateBy(x: 40.25, y: 40.5)
                c.scaleBy(x: scale, y: scale)
                c.rotate(by: rotation)
                let transform = c.ctm, clip = c.boundingBoxOfClipPath
                if product {
                  MessageBubbleBackground.fill(rect, radius: 14, color: color, in: c)
                } else {
                  c.setFillColor(color)
                  c.addPath(
                    CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
                  c.fillPath()
                }
                XCTAssertEqual(c.ctm, transform)
                XCTAssertEqual(
                  c.boundingBoxOfClipPath, clip,
                  "Corner clipping must not escape the background draw")
                return try XCTUnwrap(c.makeImage())
              }
              let expected = try Self.pixels(draw(false)), actual = try Self.pixels(draw(true))
              XCTAssertTrue(
                expected == actual,
                "Fractional, rotated, transparent and narrow bubbles must keep the exact original path output"
              )
              comparisons += 1
            }
          }
        }
      }
    }
    XCTAssertEqual(comparisons, 54)
  }
  func testPublicPlainMessageRasterCPUAndPixels() async throws {
    let text = String(repeating: " ", count: 80) + String(repeating: "\n", count: 100)
    let resources = [240, 280].enumerated().map { index, width -> PreparedText in
      let message = Message(
        id: Int64(index + 1), chatID: 1, order: OrderKey(sortKey: 1, messageID: Int64(index + 1)),
        direction: .incoming, savedAtMs: 0, kind: .text, text: text, caption: "", replyToID: nil,
        revision: 1, attachments: [])
      return PreparedText(
        message: message,
        key: TextLayoutKey(messageID: message.id, revision: 1, width: width, fontSize: 18, scale: 3)
      )
    }
    defer { resources.forEach { $0.close() } }
    for prepared in resources {
      XCTAssertGreaterThan(prepared.blocks.count, 1)
      XCTAssertGreaterThan(prepared.width, 200)
      for scale: CGFloat in [1, 2, 3] {
        for translation: CGFloat in [0, 0.25] {
          try autoreleasepool {
            let
              a = try Self.plainRaster(
                prepared, product: false, scale: scale, translation: translation),
              b = try Self.plainRaster(
                prepared, product: true, scale: scale, translation: translation)
            XCTAssertTrue(
              try Self.pixels(a) == Self.pixels(b),
              """
              The glyph-empty first block must preserve the original background, including fractional \
              device transforms
              """
            )
          }
        }
      }
    }
    let queue = DispatchQueue(label: "Kandinsky.test.public-bubble-raster", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          func batch(_ product: Bool) throws -> [String: Double] {
            let begin = try Self.cpu(), start = ProcessInfo.processInfo.systemUptime
            var digest = 0
            for _ in 0..<180 {
              for prepared in resources {
                try autoreleasepool {
                  let image = try Self.plainRaster(prepared, product: product, scale: 3)
                  digest += image.width * image.height
                }
              }
            }
            return [
              "product": product ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - start,
              "pixelWork": Double(digest)
            ]
          }
          _ = try batch(false)
          _ = try batch(true)
          var result: [[String: Double]] = []
          for product in [false, true, true, false, false, true, true, false] {
            result.append(try batch(product))
          }
          reply.resume(returning: result)
        } catch { reply.resume(throwing: error) }
      }
    }
    XCTAssertEqual(Set(batches.compactMap { $0["pixelWork"] }).count, 1)
    func median(_ values: [Double]) -> Double {
      let v = values.sorted()
      return (v[1] + v[2]) / 2
    }
    let ratio =
      median(batches.filter { $0["product"] == 1 }.map { $0["threadCPUSeconds"]! })
      / median(batches.filter { $0["product"] == 0 }.map { $0["threadCPUSeconds"]! })
    let report: [String: Any] = [
      "scope":
        """
        Public native message raster resource contract; isolated glyph-empty technical geometry, never \
        app FPS/heat acceptance
        """,
      "medianProductToOriginalBackgroundCPU": ratio, "threshold": 0.85,
      "alternatingABBAABBA": batches
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "public-bubble-raster-budget"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_PUBLIC_BUBBLE_RASTER \(String(decoding:data,as:UTF8.self))")
    XCTAssertLessThanOrEqual(
      ratio, 0.85,
      "The public renderer must avoid paying full-surface path-mask cost for a uniform bubble interior"
    )
  }
  func testBoundedOutlineAgainstOriginalBubblePath() async throws {
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let input = try JSONDecoder().decode(
      Input.self,
      from: Data(contentsOf: fixtures.appendingPathComponent("real-media/text-raster-samples.json"))
    )
    XCTAssertEqual(input.chatId, 1352)
    XCTAssertEqual(input.rows.count, 5)
    var geometries: [Geometry] = [], resources: [PreparedText] = []
    defer { resources.forEach { $0.close() } }
    for bound in [240, 280, 314] {
      for row in input.rows {
        let message = Message(
          id: row.messageId, chatID: input.chatId,
          order: OrderKey(sortKey: row.sortKey, messageID: row.messageId),
          direction: row.direction == "outgoing" ? .outgoing : .incoming, savedAtMs: row.savedAtMs,
          kind: .text, text: row.text, caption: "", replyToID: nil, revision: 1, attachments: [])
        let resource = PreparedText(
          message: message,
          key: TextLayoutKey(
            messageID: message.id, revision: 1, width: bound, fontSize: 18, scale: 3))
        resources.append(resource)
        geometries += resource.blocks.map {
          Geometry(
            width: resource.width, height: resource.height, offset: $0.offsetY,
            blockHeight: $0.height)
        }
      }
    }
    XCTAssertTrue(
      geometries.contains { $0.offset > 0 },
      "The corpus must exercise continuation blocks as well as both rounded ends")
    var comparisons = 0, maximumMean = 0.0, maximumChannel = 0, alphaMismatches = 0
    for scale: CGFloat in [1, 2, 3] {
      for radius: CGFloat in [14, 17] {
        for color in [UIColor.white.cgColor, KandinskyPalette.outgoing.cgColor] {
          let outline = try Outline(radius: radius, scale: scale, color: color)
          for geometry in geometries {
            try autoreleasepool {
              let
                a = try Self.raster(
                  geometry, radius: radius, scale: scale, color: color, outline: nil),
                b = try Self.raster(
                  geometry, radius: radius, scale: scale, color: color, outline: outline)
              XCTAssertEqual(a.width, b.width)
              XCTAssertEqual(a.height, b.height)
              let p = try Self.pixels(a), q = try Self.pixels(b)
              var error = 0
              if p != q {
                for n in p.indices {
                  let difference = abs(Int(p[n]) - Int(q[n]))
                  error += difference
                  maximumChannel = max(maximumChannel, difference)
                  if n % 4 == 3 && difference != 0 { alphaMismatches += 1 }
                }
              }
              maximumMean = max(maximumMean, Double(error) / Double(p.count))
              comparisons += 1
            }
          }
        }
      }
    }
    let work = geometries, color = KandinskyPalette.outgoing.cgColor,
      outline = try Outline(radius: 14, scale: 3, color: KandinskyPalette.outgoing.cgColor)
    let queue = DispatchQueue(label: "Kandinsky.test.bubble-background", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          func batch(_ cached: Bool) throws -> [String: Double] {
            let start = ProcessInfo.processInfo.systemUptime, begin = try Self.cpu()
            var digest = 0
            for _ in 0..<30 {
              for geometry in work {
                try autoreleasepool {
                  let image = try Self.raster(
                    geometry, radius: 14, scale: 3, color: color, outline: cached ? outline : nil)
                  digest += image.width * image.height
                }
              }
            }
            return [
              "boundedOutline": cached ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - start,
              "pixelWork": Double(digest)
            ]
          }
          _ = try batch(false)
          _ = try batch(true)
          var result: [[String: Double]] = []
          for cached in [false, true, true, false, false, true, true, false] {
            result.append(try batch(cached))
          }
          guard Set(result.compactMap { $0["pixelWork"] }).count == 1 else {
            throw NSError(domain: "UnequalBubbleWork", code: 1)
          }
          reply.resume(returning: result)
        } catch { reply.resume(throwing: error) }
      }
    }
    let report: [String: Any] = [
      "scope":
        "Production clipped-original-path pixel differential using real1352 text geometry; no whole-app FPS/heat claim",
      "productChanged": true, "geometries": geometries.count, "pixelComparisons": comparisons,
      "maximumMeanRGBAError": maximumMean, "maximumChannelError": maximumChannel,
      "alphaMismatchPixels": alphaMismatches,
      "source":
        """
        PinnedTelegram bounds background-outline work with stretchable images; this independent probe \
        retains the exact Kandinsky path and clips antialiasing to its corners
        """,
      "alternatingABBAABBA": batches
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "bubble-background-native-probe"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_BUBBLE_BACKGROUND_PROBE \(String(decoding:data,as:UTF8.self))")
    XCTAssertLessThan(maximumMean, 0.35)
    XCTAssertEqual(
      alphaMismatches, 0, "Clipped original outline must preserve edge transparency before adoption"
    )
  }
}
