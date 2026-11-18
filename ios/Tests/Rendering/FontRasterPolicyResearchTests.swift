import XCTest
import UIKit
import Darwin
@testable import Kandinsky

@MainActor final class FontRasterPolicyResearchTests: XCTestCase {
  private struct Input: Decodable {
    let chatId: Int64
    let rows: [Row]
  }
  private struct Row: Decodable {
    let messageId: Int64, sortKey: Int64, savedAtMs: Int64
    let text: String, direction: String
  }
  private nonisolated static func raster(_ prepared: PreparedText, part: Int, telegram: Bool) throws
    -> CGImage
  {
    let width = Int(ceil(prepared.width * 3)), height = Int(ceil(prepared.blocks[part].height * 3))
    let c = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if telegram {
      c.setAllowsAntialiasing(true)
      c.setAllowsFontSmoothing(false)
      c.setShouldSmoothFonts(false)
      c.setAllowsFontSubpixelPositioning(false)
      c.setShouldSubpixelPositionFonts(false)
      c.setAllowsFontSubpixelQuantization(true)
      c.setShouldSubpixelQuantizeFonts(true)
    }
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 3, y: -3)
    prepared.draw(part: part, in: c)
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
  func testCompareTelegramFontPolicyWithoutChangingProduct() async throws {
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let input = try JSONDecoder().decode(
      Input.self,
      from: Data(contentsOf: fixtures.appendingPathComponent("real-media/text-raster-samples.json"))
    )
    XCTAssertEqual(input.chatId, 1352)
    XCTAssertGreaterThanOrEqual(input.rows.count, 4)
    let resources = input.rows.map { row -> PreparedText in
      let message = Message(
        id: row.messageId, chatID: input.chatId,
        order: OrderKey(sortKey: row.sortKey, messageID: row.messageId),
        direction: row.direction == "outgoing" ? .outgoing : .incoming, savedAtMs: row.savedAtMs,
        kind: .text, text: row.text, caption: "", replyToID: nil, revision: 1, attachments: [])
      return PreparedText(
        message: message,
        key: TextLayoutKey(messageID: message.id, revision: 1, width: 280, fontSize: 18, scale: 3))
    }
    defer { resources.forEach { $0.close() } }
    var quality: [[String: Double]] = []
    for resource in resources {
      for part in resource.blocks.indices {
        let a = try Self.raster(resource, part: part, telegram: false),
          b = try Self.raster(resource, part: part, telegram: true)
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let before = try pixels(a), after = try pixels(b)
        var sum: Double = 0, maximum = 0, alpha = 0, changed = 0
        for n in before.indices {
          let difference = abs(Int(before[n]) - Int(after[n]))
          sum += Double(difference)
          maximum = max(maximum, difference)
          if n % 4 == 3 && difference != 0 { alpha += 1 }
          if difference > 16 { changed += 1 }
        }
        let mean = sum / Double(before.count)
        quality.append([
          "messageId": Double(resource.key.messageID), "part": Double(part), "meanRGBAError": mean,
          "maximumChannelError": Double(maximum), "alphaMismatchPixels": Double(alpha),
          "channelsChangedOver16Percent": Double(changed) / Double(before.count) * 100
        ])
        if part == 0 {
          for (policy, image) in [("default", a), ("telegram", b)] {
            let shot = XCTAttachment(image: UIImage(cgImage: image, scale: 3, orientation: .up))
            shot.name = "font-policy-\(policy)-\(resource.key.messageID)"
            shot.lifetime = .keepAlways
            add(shot)
          }
        }
      }
    }
    let worker = DispatchQueue(label: "Kandinsky.test.font-policy", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      worker.async {
        do {
          func batch(_ policy: Bool) throws -> [String: Double] {
            let start = ProcessInfo.processInfo.systemUptime, cpuStart = try Self.cpu()
            var work = 0
            for _ in 0..<30 {
              for resource in resources {
                for part in resource.blocks.indices {
                  try autoreleasepool {
                    let image = try Self.raster(resource, part: part, telegram: policy)
                    work += image.width * image.height + image.bitsPerPixel
                  }
                }
              }
            }
            return [
              "telegram": policy ? 1 : 0, "threadCPUSeconds": try Self.cpu() - cpuStart,
              "wallSeconds": ProcessInfo.processInfo.systemUptime - start,
              "workDigest": Double(work)
            ]
          }
          _ = try batch(false)
          _ = try batch(true)
          var result: [[String: Double]] = []
          for policy in [false, true, true, false, false, true, true, false] {
            result.append(try batch(policy))
          }
          guard Set(result.compactMap { $0["workDigest"] }).count == 1 else {
            throw NSError(domain: "UnequalRasterWork", code: 1)
          }
          reply.resume(returning: result)
        } catch { reply.resume(throwing: error) }
      }
    }
    let report: [String: Any] = [
      "scope": "Read-only native3x raster experiment, not app FPS or Release acceptance",
      "sourceChatId": input.chatId,
      "policySource": "Telegram TextNode at279f89e4d4f63f17227bf877dc3d8990f22ecd58",
      "productChanged": false, "pixelComparisons": quality, "thirtyLoopsPerBatch": true,
      "alternatingABBAABBA": batches
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "font-policy-native-benchmark"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("KANDINSKY_FONT_POLICY_BENCHMARK \(String(decoding:data,as:UTF8.self))")
    for comparison in quality {
      XCTAssertLessThan(
        comparison["meanRGBAError"]!, 0.35,
        "Reject policy adoption if glyph/color output changes beyond the existing raster quality bound"
      )
      XCTAssertEqual(comparison["alphaMismatchPixels"]!, 0, "Transparency must remain equivalent")
    }
  }
}
