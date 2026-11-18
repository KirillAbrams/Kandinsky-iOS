// Сравниваем затраты на подготовку короткого текста с сохранённым вариантом. Замер охватывает
// разметку обычных сообщений разной ширины и состава.

import XCTest
import UIKit
import Darwin
@testable import Kandinsky

@MainActor final class MetadataPreparationTests: XCTestCase {
  // Собираем затраты текущего потока в пользовательском и системном режиме. При ошибке чтения
  // прекращаем замер, чтобы нулевое время не попало в отчёт.
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
  // Берём короткие фразы, переносы, разные письменности и составные знаки. Сверяем результаты
  // разметки и проверяем, что медианное время нового способа не выше 90 процентов от прежнего.
  func testTypicalTextPreparationCPUAgainstSharedTypesetterReference() async throws {
    let result: Data = try await withCheckedThrowingContinuation { reply in
      DispatchQueue(label: "Kandinsky.test.metadata", qos: .userInitiated).async {
        do {
          let texts = [
            "Привет! Как добрался? 👋", "", "Строка первая\nСтрока вторая\n",
            "A\r\nB\u{2028}C\u{2029}D", "مرحبا بالعالم — שלום עולם 123 hello",
            "e\u{301} office ffi ﬁ co\u{ad}operate 👨‍👩‍👧‍👦 🇷🇺 1️⃣", "👋🏽✨", "中文文本 日本語の文章 한글 문장 हिन्दी भाषा"
          ]
          let inputs = texts.enumerated().map { i, text -> (Message, TextLayoutKey) in
            let row = Message(
              id: Int64(i + 1), chatID: 1352,
              order: OrderKey(sortKey: Int64(i + 1), messageID: Int64(i + 1)), direction: .incoming,
              savedAtMs: 1_793_600_000_000 + Int64(i) * 17000, kind: .text, text: text, caption: "",
              replyToID: nil, revision: 1, attachments: [])
            return (
              row,
              TextLayoutKey(
                messageID: row.id, revision: 1, width: [132, 200, 304, 360][i % 4],
                fontSize: [13, 17, 23][i % 3], scale: i % 3 + 1)
            )
          }
          // Готовим одну и ту же пачку текстов заданное число раз. Складываем размеры, объём
          // памяти и число блоков, чтобы уловить пропуск работы в одном из способов.
          func batch(_ candidate: Bool, loops: Int) throws -> [String: Double] {
            let begin = try Self.cpu()
            var work = 0.0
            for _ in 0..<loops {
              for (row, key) in inputs {
                autoreleasepool {
                  if candidate {
                    let p = PreparedText(message: row, key: key)
                    work += Double(p.width + p.height) + Double(p.byteCost) + Double(p.blocks.count)
                    p.close()
                  } else {
                    let p = PreparedTextReference(message: row, key: key, measurement: .sharedTypesetter)
                    work += Double(p.width + p.height) + Double(p.byteCost) + Double(p.blocks.count)
                    p.close()
                  }
                }
              }
            }
            return [
              "candidate": candidate ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "observableLayoutWork": work
            ]
          }
          _ = try batch(false, loops: 3)
          _ = try batch(true, loops: 3)
          var batches: [[String: Double]] = []
          for flag in [false, true, true, false, false, true, true, false] {
            batches.append(try batch(flag, loops: 100))
          }
          guard Set(batches.compactMap { $0["observableLayoutWork"] }).count == 1 else {
            throw MediaError.corrupt
          }
          // Сортируем четыре замера и усредняем два средних. Так единичная пауза не определяет
          // результат всей проверки.
          func median(_ values: [Double]) -> Double {
            let v = values.sorted()
            return (v[1] + v[2]) / 2
          }
          let ratio =
            median(batches.filter { $0["candidate"] == 1 }.map { $0["threadCPUSeconds"]! })
            / median(batches.filter { $0["candidate"] == 0 }.map { $0["threadCPUSeconds"]! })
          let report: [String: Any] = [
            "scope":
              """
              Typicalshorttext factory only; publiccandidate versus frozen48; nativeworkerCPU ABBAABBA \
              same observable layout work, not wholeappFPS
              """,
            "batches": batches, "medianCandidateReferenceRatio": ratio
          ]
          reply.resume(
            returning: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        } catch { reply.resume(throwing: error) }
      }
    }
    print("KANDINSKY_METADATA_CPU \(String(decoding:result,as:UTF8.self))")
    let attachment = XCTAttachment(data: result, uniformTypeIdentifier: "public.json")
    attachment.name = "metadata-native-cpu"
    attachment.lifetime = .keepAlways
    add(attachment)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    let ratio = try XCTUnwrap(report["medianCandidateReferenceRatio"] as? Double)
    XCTAssertLessThanOrEqual(
      ratio, 0.90,
      "Do not prepare media-only text for ordinary messages; preserve observable output")
  }
}
