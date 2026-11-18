import XCTest
import UIKit
import CoreText
import Darwin
@testable import Kandinsky

@MainActor final class TypesetterReuseTests: XCTestCase {
  private nonisolated static let texts = [
    "Привет! Как добрался? 👋", "", "Строка первая\nСтрока вторая\n", "A\r\nB\u{2028}C\u{2029}D",
    "مرحبا بالعالم — שלום עולם 123 hello", "e\u{301} office ffi ﬁ co\u{ad}operate 👨‍👩‍👧‍👦 🇷🇺 1️⃣",
    "👋🏽✨", "中文文本 日本語の文章 한글 문장 हिन्दी भाषा",
    String(
      repeating: "В мастерской проверили свет, затем отправили фотографии. 👋 مرحبا é ", count: 35),
    String(repeating: "LongUnbrokenWord👨‍👩‍👧‍👦", count: 30)
  ]
  private nonisolated static func message(_ index: Int) -> Message {
    let kinds: [MessageKind] = [.text, .photo, .video, .round, .voice, .gif, .sticker]
    let kind = kinds[(index / 10) % kinds.count], value = texts[index % texts.count]
    let a = Attachment(
      id: "attachment-geometry", relativePath: "geometry/reference",
      mime: kind == .video || kind == .round
        ? "video/mp4"
        : kind == .voice
          ? "audio/mp4"
          : kind == .gif ? "image/gif" : kind == .sticker ? "image/webp" : "image/jpeg",
      byteSize: 143600, rawWidth: 1200, rawHeight: 800, orientation: 1, durationMs: 7000,
      thumbnailKey: "", waveform: [4, 30, 128, 255, 150, 50])
    var row = Message(
      id: Int64(index + 1), chatID: 1352,
      order: OrderKey(sortKey: Int64(index + 1), messageID: Int64(index + 1)), direction: .incoming,
      savedAtMs: 1_793_600_000_000 + Int64(index) * 17000, kind: kind,
      text: kind == .text ? value : "", caption: kind == .text ? "" : value, replyToID: nil,
      revision: 1, attachments: kind == .text ? [] : [a])
    row.delivery = [MessageDelivery.pending, .accepted, .read, .failed][index % 4]
    return row
  }
  /// Отдельно задаёт расширенный режим и диаметр круглого медиа, чтобы сравнить разные варианты раскладки.
  private nonisolated static func key(_ index: Int) -> TextLayoutKey {
    TextLayoutKey(
      messageID: Int64(index + 1), revision: 1, width: [132, 200, 304, 360][index % 4],
      fontSize: [13, 17, 23][index % 3], scale: index % 3 + 1,
      roundDiameter: index % 2 == 0 ? 212 : nil)
  }
  private func raster(width: CGFloat, height: CGFloat, scale: Int, draw: (CGContext) -> Void) throws
    -> Data
  {
    let w = Int(ceil(width * CGFloat(scale))), h = Int(ceil(height * CGFloat(scale)))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: CGFloat(h))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    draw(context)
    return Data(bytes: try XCTUnwrap(context.data), count: w * h * 4)
  }
  func testNativePixelsGeometryAnchorsAndAccessibilityMatchReference() throws {
    var parts = 0
    let legacyCases = Array(0..<10) + Array(30..<40) + Array(50..<70)
    for index in legacyCases {
      try autoreleasepool {
        let row = Self.message(index), key = Self.key(index),
          before = PreparedTextReference(message: row, key: key),
          after = PreparedText(message: row, key: key)
        defer {
          before.close()
          after.close()
        }
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        XCTAssertEqual(after.byteCost, before.byteCost)
        XCTAssertEqual(after.fontPostScriptName, before.fontPostScriptName)
        XCTAssertEqual(after.mediaRect, before.mediaRect)
        XCTAssertEqual(after.mediaItemRects, before.mediaItemRects)
        XCTAssertEqual(after.mediaStampRegions, before.mediaStampRegions)
        XCTAssertEqual(after.blocks.count, before.blocks.count)
        for (a, b) in zip(after.blocks, before.blocks) {
          XCTAssertEqual(a.lines, b.lines)
          XCTAssertEqual(a.offsetY, b.offsetY)
          XCTAssertEqual(a.height, b.height)
          XCTAssertEqual(a.startUTF16, b.startUTF16)
        }
        for y in stride(from: CGFloat(0), through: after.height, by: 83) {
          let a = after.lineAnchor(y: y), b = before.lineAnchor(y: y)
          XCTAssertEqual(a?.0, b?.0)
          XCTAssertEqual(a?.1, b?.1)
          let x = after.accessibleLines(from: y, to: y + 400, limit: 128),
            z = before.accessibleLines(from: y, to: y + 400, limit: 128)
          XCTAssertEqual(x.count, z.count)
          for (u, v) in zip(x, z) {
            XCTAssertEqual(u.start, v.start)
            XCTAssertEqual(u.text, v.text)
            XCTAssertEqual(u.frame, v.frame)
          }
        }
        for i in 0..<min(before.blocks.count, after.blocks.count) {
          let a = try raster(width: before.width, height: before.blocks[i].height, scale: key.scale)
          { before.draw(part: i, in: $0) }
          let b = try raster(width: after.width, height: after.blocks[i].height, scale: key.scale) {
            after.draw(part: i, in: $0)
          }
          XCTAssertEqual(
            a, b,
            "Every glyph, bubble and timestamp pixel must match the saved reference; case\(index) part\(i)")
          parts += 1
        }
        if before.hasMediaStamp {
          let a = try raster(width: before.width, height: before.height, scale: key.scale) {
            before.drawMediaStamp(in: $0)
          }
          let b = try raster(width: after.width, height: after.height, scale: key.scale) {
            after.drawMediaStamp(in: $0)
          }
          XCTAssertEqual(a, b, "Media foreground must stay identical")
        }
      }
    }
    print("KANDINSKY_TYPESETTER_LEGACY_PIXEL_CASES 40 parts=\(parts)")
  }
  func testStudioResultsKeepActionsBelowMediaAndPromptsExposeText() throws {
    for index in 10..<30 {
      let row = Self.message(index)
      let layout = PreparedText(message: row, key: Self.key(index))
      defer { layout.close() }
      let image = try XCTUnwrap(layout.mediaRect)
      XCTAssertEqual(
        layout.mediaActions.count, row.caption.isEmpty ? (row.kind == .video ? 3 : 2) : 0)
      for action in layout.mediaActions {
        XCTAssertGreaterThanOrEqual(action.frame.minY, image.maxY)
        XCTAssertLessThanOrEqual(action.frame.maxY, layout.height)
      }
    }
    for index in [0, 2, 4, 8] {
      let source = Self.message(index)
      let prompt = Message(
        id: source.id, chatID: source.chatID, order: source.order, direction: .outgoing,
        savedAtMs: source.savedAtMs, kind: .text, text: source.text, caption: "",
        replyToID: nil, revision: 1, attachments: [])
      let layout = PreparedText(message: prompt, key: Self.key(index))
      defer { layout.close() }
      XCTAssertNil(layout.nativeTextBubbleColor)
      let lines = layout.accessibleLines(from: 0, to: layout.height, limit: 10000)
      XCTAssertFalse(lines.isEmpty)
      XCTAssertTrue(
        lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(lines.first).frame.minX, 14)
    }
  }
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
  func testPublicFactoryLayoutCPUAgainstSeparateLineReference() async throws {
    let report: Data = try await withCheckedThrowingContinuation { reply in
      DispatchQueue(label: "Kandinsky.test.typesetter", qos: .userInitiated).async {
        do {
          let inputs = (0..<10).map { (Self.message($0), Self.key($0)) }
          /// Считает размеры, число частей и учтённую стоимость, чтобы варианты выполняли одинаковую работу.
          func batch(_ candidate: Bool, loops: Int) throws -> [String: Double] {
            let begin = try Self.cpu()
            var work = 0.0
            for _ in 0..<loops {
              for (row, key) in inputs {
                autoreleasepool {
                  if candidate {
                    let value = PreparedText(message: row, key: key)
                    work +=
                      Double(value.width + value.height) + Double(value.blocks.count)
                      + Double(value.byteCost)
                    value.close()
                  } else {
                    let value = PreparedTextReference(message: row, key: key)
                    work +=
                      Double(value.width + value.height) + Double(value.blocks.count)
                      + Double(value.byteCost)
                    value.close()
                  }
                }
              }
            }
            return [
              "candidate": candidate ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "layoutWork": work
            ]
          }
          _ = try batch(false, loops: 2)
          _ = try batch(true, loops: 2)
          var batches: [[String: Double]] = []
          for flag in [false, true, true, false, false, true, true, false] {
            batches.append(try batch(flag, loops: 35))
          }
          guard Set(batches.compactMap { $0["layoutWork"] }).count == 1 else {
            throw MediaError.corrupt
          }
          func median(_ values: [Double]) -> Double {
            let v = values.sorted()
            return (v[1] + v[2]) / 2
          }
          let ratio =
            median(batches.filter { $0["candidate"] == 1 }.map { $0["threadCPUSeconds"]! })
            / median(batches.filter { $0["candidate"] == 0 }.map { $0["threadCPUSeconds"]! })
          let value: [String: Any] = [
            "scope":
              """
              PublicPreparedText factory versus independently frozen47; nativeworkerCPU, sameinputs \
              andlayoutwork, ABBAABBA; not wholeappFPS
              """,
            "batches": batches, "medianCandidateReferenceRatio": ratio
          ]
          reply.resume(
            returning: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        } catch { reply.resume(throwing: error) }
      }
    }
    print("KANDINSKY_TYPESETTER_CPU \(String(decoding:report,as:UTF8.self))")
    let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
    attachment.name = "typesetter-native-cpu"
    attachment.lifetime = .keepAlways
    add(attachment)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any])
    let ratio = try XCTUnwrap(parsed["medianCandidateReferenceRatio"] as? Double)
    XCTAssertLessThanOrEqual(
      ratio, 0.85,
      "Remove redundant CoreText preparation without changing layout, pixels or charged work")
  }
}
