// Проверяем, что лента повторно использует готовые слои сообщений, готовит новые рисунки в фоне и
// освобождает старые. Здесь же сверяем время сообщений и поведение поля при составном вводе.

import XCTest
import UIKit
@testable import Kandinsky

final class MessageTimestampTests: XCTestCase {
  // Получаем эталон часов и минут стандартным форматированием даты в заданном поясе. Отдельный
  // расчёт позволяет проверить быстрый путь приложения.
  private func reference(_ milliseconds: Int64, zone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    formatter.timeZone = zone
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
  }
  // Сверяем известные отметки у полуночи, в поясе с дробным сдвигом и при смене сезонного
  // времени. Эти места ловят ошибки округления и перехода через сутки.
  func testKnownMidnightFractionalZoneAndDaylightSavingTimes() throws {
    let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0)),
      newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let samples: [(Int64, TimeZone, String)] = [
      (0, utc, "00:00"), (59_999, utc, "00:00"), (60_000, utc, "00:01"), (-1, utc, "23:59"),
      (-60_001, utc, "23:58"),
      (0, try XCTUnwrap(TimeZone(secondsFromGMT: 20_700)), "05:45"),
      (0, try XCTUnwrap(TimeZone(secondsFromGMT: -12_600)), "20:30"),
      (1_710_053_999_999, newYork, "01:59"), (1_710_054_000_000, newYork, "03:00"),
      (1_730_613_599_999, newYork, "01:59"), (1_730_613_600_000, newYork, "01:00")
    ]
    for (milliseconds, zone, expected) in samples {
      XCTAssertEqual(
        MessageTimestamp.string(for: milliseconds, timeZone: zone), expected,
        "\(milliseconds) in \(zone.identifier)")
    }
  }
  // Сравниваем разные даты и названные часовые пояса с системным форматированием. Отдельно
  // проверяем вызов без пояса, который должен взять текущую настройку телефона.
  func testNamedZonesAndHistoricAndFutureTimesMatchFoundation() throws {
    let names = [
      "UTC", "Europe/Samara", "America/New_York", "Europe/Paris", "Asia/Kathmandu",
      "Pacific/Chatham", "Australia/Lord_Howe", "Africa/Monrovia"
    ]
    let dates: [Int64] = [
      -2_840_140_800_123, -2_208_988_800_001, -1_001, -1_000, -999, -1, 0, 1, 59_999, 60_000,
      1_700_000_000_000, 1_710_053_999_999, 1_710_054_000_000, 1_730_613_599_999, 1_730_613_600_000,
      2_147_483_647_000, 4_102_444_800_000
    ]
    for name in names {
      let zone = try XCTUnwrap(TimeZone(identifier: name))
      for date in dates {
        XCTAssertEqual(
          MessageTimestamp.string(for: date, timeZone: zone), reference(date, zone: zone),
          "\(date) in \(name)")
      }
    }
    for date in dates {
      XCTAssertEqual(MessageTimestamp.string(for: date), reference(date, zone: TimeZone.current))
    }
  }
  // Форматируем отметки с разными поясами параллельно и повторяем запросы. Так видна ошибка, при
  // которой один поток получает часовой пояс другого.
  func testConcurrentDifferentZonesHaveNoSharedFormatterState() async throws {
    let zones = try ["UTC", "America/New_York", "Asia/Kathmandu", "Europe/Paris"].map {
      try XCTUnwrap(TimeZone(identifier: $0))
    }
    let samples = (0..<128).map { i -> (Int64, TimeZone, String) in
      let date = Int64(i) * 86_400_137 - 1_710_054_000_000, zone = zones[i % zones.count]
      return (date, zone, reference(date, zone: zone))
    }
    let valid = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      for (date, zone, expected) in samples {
        group.addTask {
          (0..<8).allSatisfy { _ in MessageTimestamp.string(for: date, timeZone: zone) == expected }
        }
      }
      var valid = true
      for await value in group { valid = valid && value }
      return valid
    }
    XCTAssertTrue(valid, "Concurrent layout workers must not exchange timezone or timestamp state")
  }
  // Сравниваем пакет отметок с созданием системного форматировщика для каждой строки. Контрольная
  // сумма результатов должна совпасть, а время быстрого пути укладывается в половину времени
  // образца.
  func testTimestampBatchCostsAtMostHalfTheFreshFormatterPath() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Samara"))
    // Форматируем много отметок одним способом и возвращаем длительность вместе с контрольным
    // числом. Число помогает исключить ошибочный замер с пропущенными строками.
    func sample(_ operation: (Int64) -> String) -> (Double, Int) {
      var digest = 0
      let began = ProcessInfo.processInfo.systemUptime
      for i in 0..<2000 {
        digest += operation(1_700_000_000_000 + Int64(i) * 61_137).utf8.reduce(0) { $0 + Int($1) }
      }
      return (ProcessInfo.processInfo.systemUptime - began, digest)
    }
    _ = MessageTimestamp.string(for: 0, timeZone: zone)
    _ = reference(0, zone: zone)
    var current: [Double] = [], previous: [Double] = []
    for pair in 0..<3 {
      let a: (Double, Int), b: (Double, Int)
      if pair.isMultiple(of: 2) {
        b = sample { self.reference($0, zone: zone) }
        a = sample { MessageTimestamp.string(for: $0, timeZone: zone) }
      } else {
        a = sample { MessageTimestamp.string(for: $0, timeZone: zone) }
        b = sample { self.reference($0, zone: zone) }
      }
      XCTAssertEqual(a.1, b.1)
      current.append(a.0)
      previous.append(b.0)
    }
    let ratio = current.sorted()[1] / previous.sorted()[1]
    print(
      "KANDINSKY_TIMESTAMP_BATCH currentSeconds=\(current) previousSeconds=\(previous) medianRatio=\(ratio)"
    )
    XCTAssertLessThanOrEqual(
      ratio, 0.50,
      "Message layout must avoid constructing a fresh general-purpose date formatter for each time label"
    )
  }
}

@MainActor final class RetainedSceneTests: XCTestCase {
  // Занимаем защиту текста на рабочем потоке и применяем видимую сцену. Основной поток должен
  // вернуться сразу, а после освобождения защиты должны появиться пиксели метки.
  func testReconciliationDoesNotWaitForWorkerOwnedTextLock() async throws {
    let prepared = visual(.video), root = CALayer(), scene = RetainedChatScene(container: root)
    let lock = try XCTUnwrap(
      Mirror(reflecting: prepared).children.first { $0.label == "lock" }?.value as? NSLock)
    defer {
      scene.close()
      prepared.close()
    }
    // Дожидаемся захвата защиты, замеряем действие и ограничиваем ожидание освобождения. Условия
    // воспроизводят долгую подготовку текста за пределами основного потока.
    func elapsedWithWorkerHoldingLock(_ action: () -> Void) throws -> Double {
      let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0),
        finished = DispatchSemaphore(value: 0)
      DispatchQueue(label: "Kandinsky.test.controlled-text-lock").async {
        lock.lock()
        held.signal()
        release.wait()
        lock.unlock()
        finished.signal()
      }
      XCTAssertEqual(held.wait(timeout: .now() + 1), .success)
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { release.signal() }
      let begin = ProcessInfo.processInfo.systemUptime
      action()
      let elapsed = ProcessInfo.processInfo.systemUptime - begin
      XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
      return elapsed
    }
    // Отдельный прежний вызов рисования использует ту же настоящую защиту текста
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: prepared.width, height: prepared.height), format: format)
    let legacy = try elapsedWithWorkerHoldingLock {
      _ = renderer.image { prepared.drawMediaStamp(in: $0.cgContext) }
    }
    let current = try elapsedWithWorkerHoldingLock {
      scene.apply(
        SceneSnapshot(
          ticket: scene.ticket,
          fragments: [
            SceneFragment(
              prepared: prepared, part: 0,
              frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
          ]))
    }
    print(
      "KANDINSKY_TEXT_LOCK_REPLAY synchronousSeconds=\(legacy) candidateReconcileSeconds=\(current)"
    )
    XCTAssertGreaterThanOrEqual(
      legacy, 0.06,
      "The controlled baseline must genuinely reach and wait on the worker-owned native lock")
    XCTAssertLessThan(
      current, 0.04,
      "Scene reconciliation must return without waiting for a text raster or metadata lock")
    let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer),
      deadline = Date().addingTimeInterval(3)
    // Ищем в дочернем слое готовые пиксели надписи. Сам факт создания слоя ещё не означает, что
    // метка нарисована.
    func ready() -> Bool {
      (node.sublayers ?? []).contains { overlay in
        (overlay.sublayers ?? []).contains { $0.contents != nil }
      }
    }
    while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(
      ready(),
      "Avoiding the lock on main must still publish the real metadata after the worker releases it")
  }
  // Проверяем, что метки разных вложений появляются позже на маленьких поверхностях. При
  // повторном использовании рисунок сохраняется, а при снятии слоя его память освобождается.
  func testMediaMetadataDoesNotDrawSynchronouslyAndUsesSmallBackingSurfaces() async throws {
    for kind in [MessageKind.photo, .video, .round, .gif, .sticker] {
      let root = CALayer(), scene = RetainedChatScene(container: root), prepared = visual(kind)
      root.bounds = CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height)
      scene.apply(
        SceneSnapshot(
          ticket: scene.ticket,
          fragments: [SceneFragment(prepared: prepared, part: 0, frame: root.bounds)]))
      let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer),
        overlay = try XCTUnwrap(node.sublayers?.first)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = false
      format.preferredRange = .standard
      let image = try XCTUnwrap(
        UIGraphicsImageRenderer(size: root.bounds.size, format: format).image {
          overlay.render(in: $0.cgContext)
        }.cgImage)
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      let alpha = (0..<image.width * image.height).reduce(0) { $0 + Int(bytes[$1 * 4 + 3]) }
      XCTAssertEqual(
        alpha, 0,
        "A fresh \(kind) metadata layer must not rasterize on the scrolling thread before a worker can publish"
      )
      let deadline = Date().addingTimeInterval(3)
      while !(overlay.sublayers ?? []).contains(where: { $0.contents != nil }), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      let surfaces = overlay.sublayers ?? [overlay]
      XCTAssertLessThanOrEqual(
        surfaces.reduce(CGFloat.zero) { $0 + $1.bounds.width * $1.bounds.height }, 8192,
        "Metadata needs only its pills/glyphs, not a full-message transparent bitmap")
      XCTAssertTrue(
        surfaces.contains { $0.contents != nil },
        "Actual prepared stamp pixels must eventually appear")
      let children = surfaces, images = children.map { $0.contents as AnyObject? }
      for y in 0..<1000 {
        scene.apply(
          SceneSnapshot(
            ticket: scene.ticket,
            fragments: [
              SceneFragment(
                prepared: prepared, part: 0, frame: root.bounds.offsetBy(dx: 0, dy: CGFloat(y)))
            ]))
      }
      for (index, child) in children.enumerated() {
        XCTAssertTrue(
          images[index] === (child.contents as AnyObject?),
          "Moving a retained message must reuse its metadata image")
      }
      scene.close()
      for child in children {
        XCTAssertNil(child.contents, "Retirement clears the native metadata backing")
      }
      prepared.close()
    }
  }
  // Готовим фото с подписью и проверяем, что поверх фото не создан пустой слой меток. Иначе
  // каждое такое сообщение держало бы лишнюю поверхность.
  func testCaptionedPhotoDoesNotAllocateAnEmptyMetadataLayer() throws {
    let root = CALayer(), scene = RetainedChatScene(container: root),
      prepared = visual(.photo, caption: "Настоящая подпись")
    defer {
      scene.close()
      prepared.close()
    }
    scene.apply(
      SceneSnapshot(
        ticket: scene.ticket,
        fragments: [
          SceneFragment(
            prepared: prepared, part: 0,
            frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
        ]))
    let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
    XCTAssertTrue(
      (node.sublayers ?? []).isEmpty,
      "Caption time is already in the body; there are no overlaid photo marks to rasterize")
  }
  // Сверяем фоновый рисунок меток с полным образцом на узких и широких вложениях. После смены
  // версии запоздавший рисунок прежней метки не должен оказаться в новом слое.
  func testAsyncMetadataMatchesFullReferenceAtNativeScalesAndRejectsLateRevision() async throws {
    for scale in [1, 3] {
      for direction in [MessageDirection.incoming, .outgoing] {
        for kind in [MessageKind.photo, .video, .round, .gif, .sticker] {
          for bound in [60, 304] {
            let root = CALayer(), scene = RetainedChatScene(container: root),
              prepared = visual(kind, direction: direction, scale: scale, bound: bound)
            root.bounds = CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height)
            // Помещаем в сцену один подготовленный фрагмент с её текущим номером. Так смена
            // версии сообщения проверяется через обычное обновление видимых слоёв.
            func apply(_ value: PreparedText) {
              scene.apply(
                SceneSnapshot(
                  ticket: scene.ticket,
                  fragments: [SceneFragment(prepared: value, part: 0, frame: root.bounds)]))
            }
            apply(prepared)
            let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer),
              retired = try XCTUnwrap(node.sublayers?.first)
            let revision = visual(
              kind, direction: direction, revision: 2, scale: scale, bound: bound)
            apply(revision)
            let overlay = try XCTUnwrap(node.sublayers?.first),
              deadline = Date().addingTimeInterval(3)
            while !(overlay.sublayers ?? []).contains(where: { $0.contents != nil }),
              Date() < deadline
            { try await Task.sleep(nanoseconds: 5_000_000) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = CGFloat(scale)
            format.opaque = false
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: root.bounds.size, format: format)
            let expected = try XCTUnwrap(
              renderer.image { revision.drawMediaStamp(in: $0.cgContext) }.cgImage)
            let actual = try XCTUnwrap(renderer.image { overlay.render(in: $0.cgContext) }.cgImage)
            // Перекладываем картинку в одинаковый цвет и записываем четыре составляющие каждого
            // пикселя. Это позволяет посчитать ошибку только там, где есть нарисованные метки.
            func bytes(_ image: CGImage) throws -> [UInt8] {
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
            let a = try bytes(actual), b = try bytes(expected)
            XCTAssertEqual(a.count, b.count)
            var error = 0, channels = 0
            for pixel in 0..<actual.width * actual.height
            where a[pixel * 4 + 3] > 0 || b[pixel * 4 + 3] > 0 {
              for channel in 0..<4 {
                error += abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel]))
                channels += 1
              }
            }
            let mean = Double(error) / Double(max(1, channels))
            print(
              """
              KANDINSKY_ASYNC_STAMP_PIXELS kind=\(kind) direction=\(direction) scale=\(scale) \
              bound=\(bound) mean=\(mean)
              """
            )
            XCTAssertGreaterThan(channels, 0)
            XCTAssertLessThan(
              mean, 2,
              """
              Metadata image crops must preserve the full frozen draw path, including glyph edges and \
              overlapping pills
              """
            )
            scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: []))
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertNil(retired.superlayer)
            XCTAssertNil(retired.contents)
            for child in overlay.sublayers ?? [] { XCTAssertNil(child.contents) }
            scene.close()
            prepared.close()
            revision.close()
          }
        }
      }
    }
  }
  // Передаём сразу 128 фотографий и больше не двигаем видимую область. Все маленькие задачи
  // должны завершиться сами, иначе часть меток зависла бы до следующего касания.
  func testAllBoundedMetadataJobsCompleteWithoutAnotherScroll() async throws {
    let root = CALayer(), scene = RetainedChatScene(container: root)
    let prepared = (1...128).map { visual(.photo, id: Int64($0)) }
    defer {
      scene.close()
      prepared.forEach { $0.close() }
    }
    let fragments = prepared.enumerated().map { index, value in
      SceneFragment(
        prepared: value, part: 0,
        frame: CGRect(x: 0, y: CGFloat(index) * 240, width: value.width, height: value.height))
    }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: fragments))
    // Считаем слои, у которых появилась хотя бы одна нарисованная метка. Сравниваем число с
    // исходным набором, чтобы найти застрявшие задачи.
    func ready() -> Int {
      (root.sublayers ?? []).filter { node in
        (node.sublayers ?? []).contains { overlay in
          (overlay.sublayers ?? []).contains { $0.contents != nil }
        }
      }.count
    }
    let deadline = Date().addingTimeInterval(3)
    while ready() < prepared.count, Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(
      ready(), prepared.count,
      "Every admitted scene fragment must finish metadata without waiting for a later scroll or network update"
    )
  }
  // Собираем вложение нужного вида и готовим его при указанных размерах и версии. Одна заготовка
  // позволяет менять только свойство, которое проверяется в очередном опыте.
  private func visual(
    _ kind: MessageKind, direction: MessageDirection = .incoming, caption: String = "",
    revision: Int = 1, scale: Int = 3, bound: Int = 304, id: MessageID = 1
  ) -> PreparedText {
    let attachment = Attachment(
      id: "visual", relativePath: "remote/visual.jpg",
      mime: kind == .gif ? "image/gif" : "image/jpeg", byteSize: 100, rawWidth: 640, rawHeight: 480,
      orientation: 1, durationMs: 8000, thumbnailKey: "visual")
    let row = Message(
      id: id, chatID: 4, order: OrderKey(sortKey: id, messageID: id), direction: direction,
      savedAtMs: 0, kind: kind, text: "", caption: caption, replyToID: nil, revision: revision,
      attachments: [attachment])
    return PreparedText(
      message: row,
      key: TextLayoutKey(
        messageID: id, revision: revision, width: bound, fontSize: 18, scale: scale))
  }
  // Для пяти видов вложений без подписи проверяем отсутствие задания на рисунок и полноразмерной
  // картинки. Цвет фона и прозрачность можно показать без этой работы.
  func testCaptionlessMediaHasNoStaticBitmapOrPendingRaster() async throws {
    for kind in [MessageKind.photo, .video, .round, .gif, .sticker] {
      let root = CALayer(), scene = RetainedChatScene(container: root), prepared = visual(kind)
      let frame = CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height)
      scene.apply(
        SceneSnapshot(
          ticket: scene.ticket,
          fragments: [SceneFragment(prepared: prepared, part: 0, frame: frame)]))
      let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
      XCTAssertNil(
        node.raster, "A captionless \(kind) has no text to send to the static raster worker")
      try await Task.sleep(nanoseconds: 30_000_000)
      XCTAssertNil(
        node.contents, "A solid/transparent media background must not own a full RGBA image")
      XCTAssertEqual(scene.metrics.recordings, 0)
      scene.close()
      prepared.close()
    }
  }
  // Сравниваем итоговый фон, прозрачные углы и метки с полным рисунком для обоих направлений
  // сообщения. Так уменьшение памяти не меняет внешний вид.
  func testCaptionlessNativeBackgroundMatchesReferencePixels() async throws {
    for kind in [MessageKind.photo, .video, .round, .gif, .sticker] {
      for direction in [MessageDirection.incoming, .outgoing] {
        for scale in [1, 3] {
          let root = CALayer(), scene = RetainedChatScene(container: root),
            prepared = visual(kind, direction: direction, scale: scale)
          let size = CGSize(width: prepared.width, height: prepared.height)
          root.bounds = CGRect(origin: .zero, size: size)
          scene.apply(
            SceneSnapshot(
              ticket: scene.ticket,
              fragments: [SceneFragment(prepared: prepared, part: 0, frame: root.bounds)]))
          let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
          for _ in 0..<200 where node.raster != nil { try await Task.sleep(nanoseconds: 5_000_000) }
          XCTAssertNil(node.raster, "The reference comparison needs the completed scene")
          // Проверяем, успело ли фоновое рисование заполнить хотя бы одну метку. Сравнение с
          // полным образцом начинаем только после этого.
          func stampReady() -> Bool {
            (node.sublayers ?? []).contains { overlay in
              (overlay.sublayers ?? []).contains { $0.contents != nil }
            }
          }
          let stampDeadline = Date().addingTimeInterval(3)
          while !stampReady(), Date() < stampDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
          }
          XCTAssertTrue(
            stampReady(), "The full reference comparison waits for actual async metadata pixels")
          let format = UIGraphicsImageRendererFormat()
          format.scale = CGFloat(scale)
          format.opaque = false
          format.preferredRange = .standard
          let renderer = UIGraphicsImageRenderer(size: size, format: format)
          let expected = try XCTUnwrap(
            renderer.image {
              prepared.draw(part: 0, in: $0.cgContext)
              prepared.drawMediaStamp(in: $0.cgContext)
            }.cgImage)
          let actual = try XCTUnwrap(renderer.image { root.render(in: $0.cgContext) }.cgImage)
          // Приводим снимок и образец к одинаковому цвету и шагу строки. Полученные байты
          // позволяют сравнить скругления и полупрозрачные метки.
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
          let a = try pixels(actual), b = try pixels(expected)
          XCTAssertEqual(a.count, b.count)
          let mean =
            zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(b.count)
          print(
            "KANDINSKY_MEDIA_BACKGROUND_PIXELS kind=\(kind) direction=\(direction) scale=\(scale) mean=\(mean)"
          )
          XCTAssertLessThan(
            mean, 0.35, "Keep existing media fill, corners, transparency and stamps")
          scene.close()
          prepared.close()
        }
      }
    }
  }
  // Сначала готовим фото с подписью, убираем её и возвращаем снова. Слой должен сбросить прежний
  // рисунок, а сплошной фон исчезнуть после возврата подписи.
  func testMediaRevisionCannotPublishRetiredCaptionRasterOverNativeBackground() async throws {
    let root = CALayer(), scene = RetainedChatScene(container: root)
    let captioned = visual(.photo, caption: "Подпись 👨‍👩‍👧‍👦 مرحبا", revision: 1),
      plain = visual(.photo, revision: 2)
    // Применяем фрагмент в одних и тех же координатах при каждой смене текста. Тогда видно, что
    // осталось в том же слое после удаления подписи.
    func apply(_ prepared: PreparedText) {
      scene.apply(
        SceneSnapshot(
          ticket: scene.ticket,
          fragments: [
            SceneFragment(
              prepared: prepared, part: 0,
              frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
          ]))
    }
    apply(captioned)
    let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
    XCTAssertNotNil(node.raster, "Captioned media still prepares actual text pixels")
    apply(plain)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(root.sublayers?.first === node)
    XCTAssertNil(node.raster)
    XCTAssertNil(node.contents)
    apply(captioned)
    for _ in 0..<100 where node.contents == nil { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertNotNil(node.contents, "Restoring a caption must restore the worker bitmap")
    XCTAssertNil(
      node.backgroundColor, "The old captionless fill cannot remain under the text bitmap")
    scene.close()
    captioned.close()
    plain.close()
  }
  // Добавляем новый фрагмент и убеждаемся, что применение сцены не рисует его сразу. Готовые
  // пиксели обновляют только нужный слой, а удалённый слой не принимает опоздавший рисунок.
  func testNewFragmentRasterDoesNotBlockSceneApplyAndCannotPublishAfterRetirement() async throws {
    let container = CALayer()
    let active = RetainedChatScene(container: container)
    var fullSceneRequests = 0
    active.onImageReady = { fullSceneRequests += 1 }
    defer { active.close() }
    let prepared = PreparedText(
      message: message("Новый текст 👨‍👩‍👧‍👦 مرحبا"),
      key: TextLayoutKey(messageID: 1, revision: 1, width: 240, fontSize: 18, scale: 3))
    let fragment = SceneFragment(
      prepared: prepared, part: 0,
      frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
    active.apply(SceneSnapshot(ticket: active.ticket, fragments: [fragment]))
    let layer = try XCTUnwrap(container.sublayers?.first as? MessageLayer)
    XCTAssertEqual(
      active.metrics.recordings, 0,
      "Applying layout must not rasterize new text synchronously on the UI thread")
    let deadline = Date().addingTimeInterval(1)
    while layer.contents == nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertNotNil(layer.contents)
    XCTAssertEqual(active.metrics.recordings, 1)
    print("KANDINSKY_RASTER_PUBLICATION_SCENE_REQUESTS \(fullSceneRequests)")
    XCTAssertEqual(
      fullSceneRequests, 0,
      "Publishing already-placed static pixels must not request a full history scene update")
    let raw = try XCTUnwrap(layer.contents)
    XCTAssertEqual(
      CFGetTypeID(raw as CFTypeRef), CGImage.typeID,
      "Published content is a worker bitmap, not a synchronous CA backing store")
    let bitmap = raw as! CGImage
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = false
    format.preferredRange = .standard
    let reference = try XCTUnwrap(
      UIGraphicsImageRenderer(size: fragment.frame.size, format: format).image {
        prepared.draw(part: 0, in: $0.cgContext)
      }.cgImage)
    XCTAssertEqual(bitmap.width, reference.width)
    XCTAssertEqual(bitmap.height, reference.height)
    // Переводим фоновые пиксели и образец в один цветовой формат. Сравниваем готовый рисунок
    // вместо одного признака, что слой заполнен.
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
    let rendered = try XCTUnwrap(
      UIGraphicsImageRenderer(size: fragment.frame.size, format: format).image {
        layer.render(in: $0.cgContext)
      }.cgImage)
    let actual = try pixels(rendered), expected = try pixels(reference)
    let difference =
      zip(actual, expected).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
      / Double(expected.count)
    print("KANDINSKY_ASYNC_RASTER_PIXEL_MEAN_ERROR \(difference)")
    XCTAssertLessThan(
      difference, 2,
      """
      Worker ink and its retained native background must preserve UIKit reference pixels, including \
      Unicode/emoji and orientation
      """
    )
    active.advanceGeneration()
    active.apply(SceneSnapshot(ticket: active.ticket, fragments: [fragment]))
    let retired = try XCTUnwrap(container.sublayers?.first as? MessageLayer)
    active.apply(SceneSnapshot(ticket: active.ticket, fragments: []))
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(retired.contents, "A retired fragment cannot acquire a late bitmap")
    XCTAssertEqual(active.metrics.liveFragments, 0)
  }
  // Начинаем составной ввод и обновляем внешнее состояние. Промежуточный текст и выделенная
  // область должны остаться до завершения ввода, после чего обычная замена снова действует.
  func testNativeComposingRangeSurvivesStateRefresh() {
    let input = UITextView()
    input.text = "draft"
    input.setMarkedText("👨‍👩‍👧‍👦 é مرحبا", selectedRange: NSRange(location: 0, length: 0))
    let composing = input.text
    XCTAssertNotNil(input.markedTextRange)
    ComposerInputBridge.synchronize(input, to: "remote")
    XCTAssertEqual(input.text, composing)
    XCTAssertNotNil(input.markedTextRange)
    ComposerInputBridge.finish(input)
    ComposerInputBridge.synchronize(input, to: "Привет 👨‍👩‍👧‍👦 é مرحبا")
    XCTAssertNil(input.markedTextRange)
    XCTAssertEqual(input.text, "Привет 👨‍👩‍👧‍👦 é مرحبا")
  }
  // Создаём простое входящее сообщение с указанным текстом и постоянным номером. Так проверка может
  // менять содержание, сохраняя остальные условия.
  private func message(_ text: String) -> Message {
    Message(
      id: 1, chatID: 4, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
      savedAtMs: 1, kind: .text, text: text, caption: "", replyToID: nil, revision: 1,
      attachments: [])
  }
  // Двигаем видимую область и считаем обращения к уже готовому рисунку. Слой и его координаты
  // сохраняются, а само движение не перечитывает пиксели.
  func testScrollingReadyLayersDoesNotRecheckStaticPixels() async throws {
    let root = CALayer(), scene = RetainedChatScene(container: root)
    let resource = PreparedText(
      message: message("Рисунок уже готов"),
      key: TextLayoutKey(messageID: 1, revision: 1, width: 200, fontSize: 17, scale: 1))
    defer { scene.close() }
    let fragment = SceneFragment(
      prepared: resource, part: 0,
      frame: CGRect(x: 8, y: 120, width: resource.width, height: resource.blocks[0].height))
    let snapshot = SceneSnapshot(ticket: scene.ticket, fragments: [fragment])
    scene.apply(snapshot)
    let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
    let deadline = Date().addingTimeInterval(3)
    while node.contents == nil, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    let pixels = try XCTUnwrap(node.contents as AnyObject?)
    let getter = #selector(getter: CALayer.contents)
    let method = try XCTUnwrap(class_getInstanceMethod(CALayer.self, getter))
    let original = method_getImplementation(method)
    typealias GetContents = @convention(c) (CALayer, Selector) -> AnyObject?
    let getContents = unsafeBitCast(original, to: GetContents.self)
    var reads = 0
    let observe: @convention(block) (CALayer) -> AnyObject? = { layer in
      if layer === node { reads += 1 }
      return getContents(layer, getter)
    }
    let replacement = imp_implementationWithBlock(observe)
    method_setImplementation(method, replacement)
    for y in 120..<128 {
      scene.viewport = CGRect(x: 0, y: CGFloat(y), width: 320, height: 500)
      scene.apply(snapshot)
    }
    method_setImplementation(method, original)
    imp_removeBlock(replacement)
    XCTAssertEqual(reads, 0, "A viewport move must not inspect the ready static bitmap")
    XCTAssertTrue(node.contents as AnyObject? === pixels)
    XCTAssertEqual(node.frame, fragment.frame)
  }

  // Обновляем положение длинного сообщения без смены разметки. Сохраняем прежние слои и
  // проверяем, что запрос от старой сцены или закрытого экрана не вернёт их обратно.
  func testPositionOnlyRetainsNodesAndRejectsLateLayout() async throws {
    let scene = RetainedChatScene(container: CALayer())
    let key = TextLayoutKey(messageID: 1, revision: 1, width: 200, fontSize: 17, scale: 1)
    let resource = PreparedText(
      message: message(String(repeating: "مرحبا 👨‍👩‍👧‍👦 é text\n", count: 160)), key: key)
    XCTAssertFalse(resource.fontPostScriptName.contains("Times"))
    XCTAssertGreaterThan(resource.blocks.count, 5)
    // Собираем положение фрагментов с текущим номером сцены и нужным сдвигом. Это позволяет
    // отделить движение слоёв от подготовки новых частей.
    func snapshot(_ y: CGFloat) -> SceneSnapshot {
      SceneSnapshot(
        ticket: scene.ticket,
        fragments: (0..<5).map { part in
          SceneFragment(
            prepared: resource, part: part,
            frame: CGRect(
              x: 10, y: y + CGFloat(part) * 380, width: 200, height: resource.blocks[part].height))
        })
    }
    scene.apply(snapshot(0))
    let identity = scene.nodeIdentity(for: FragmentID(messageID: 1, part: 0))
    let ready = Date().addingTimeInterval(3)
    while scene.metrics.recordings < 5, Date() < ready {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let count = scene.metrics.recordings
    XCTAssertEqual(count, 5)
    for n in 0..<1000 { scene.apply(snapshot(CGFloat(n % 30))) }
    XCTAssertEqual(scene.nodeIdentity(for: FragmentID(messageID: 1, part: 0)), identity)
    XCTAssertEqual(scene.metrics.recordings, count)
    let oldTicket = scene.ticket
    scene.advanceGeneration()
    let late = PreparedText(message: message("late"), key: key)
    XCTAssertFalse(scene.accept(late, ticket: oldTicket))
    late.close()
    XCTAssertEqual(late.closeCount, 1)
    let long = PreparedText(
      message: message(String(repeating: "a\n", count: 5000)),
      key: TextLayoutKey(messageID: 1, revision: 2, width: 100, fontSize: 3, scale: 1))
    XCTAssertGreaterThan(long.blocks.count, 200)
    XCTAssertTrue(long.blocks.allSatisfy { $0.height > 0 && $0.height <= 512 })
    scene.apply(
      SceneSnapshot(
        ticket: scene.ticket,
        fragments: (0..<200).map {
          SceneFragment(
            prepared: long, part: $0,
            frame: CGRect(x: 0, y: 0, width: 100, height: long.blocks[$0].height))
        }))
    XCTAssertLessThanOrEqual(scene.metrics.liveFragments, 128)
    scene.close()
    XCTAssertEqual(scene.metrics.liveFragments, 0)
    XCTAssertEqual(scene.metrics.activeFrameClocks, 0)
    let afterClose = PreparedText(message: message("closed"), key: key)
    XCTAssertFalse(scene.accept(afterClose, ticket: scene.ticket))
    XCTAssertEqual(afterClose.closeCount, 1)
  }
  // Добавляем сообщение через обычное хранилище и ждём обновления полной сцены. Старый слой
  // остаётся тем же, а вклад нового сообщения в число рисунков равен одному.
  func testRepositoryDeltaRetainsUnchangedNativeNodesThroughFullCoordinator() async throws {
    let h = try await RepositoryHarness.open()
    var ids: [MessageID] = []
    for n in 0..<10 {
      ids.append(
        try await h.repo.send(
          SendCommand(operationID: "retained-\(n)", chatID: 2, text: "row \(n)")
        ).inserted[0].id)
    }
    let host = ChatScrollHost(), parent = UIViewController(), child = UIViewController()
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    parent.addChild(child)
    child.view = host
    parent.view.addSubview(host)
    child.didMove(toParent: parent)
    window.rootViewController = parent
    window.makeKeyAndVisible()
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    // Ждём готовности сцены короткими паузами не дольше шести секунд. Если обновление не пришло,
    // проверка сообщает об этом явно.
    func waitFor(_ condition: () -> Bool) async throws {
      let end = Date().addingTimeInterval(6)
      while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
      XCTAssertTrue(condition(), "Full coordinator must become ready")
    }
    // Ищем слой заданного сообщения в дереве сцены. Сравнение найденного объекта показывает, был
    // ли он переиспользован.
    func layer(_ root: CALayer, _ id: MessageID) -> MessageLayer? {
      if let value = root as? MessageLayer, value.fragment?.id.messageID == id { return value }
      for child in root.sublayers ?? [] { if let value = layer(child, id) { return value } }
      return nil
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: ids[0], followsBottom: false))
    try await waitFor { host.metrics.liveFragments == 10 && host.metrics.recordings == 10 }
    let native = try XCTUnwrap(layer(host.layer, ids[0])), recorded = host.metrics.recordings
    let delta = try await h.repo.send(
      SendCommand(operationID: "retained-new", chatID: 2, text: "new"))
    host.apply(delta)
    try await waitFor {
      host.metrics.liveFragments == 11 && host.metrics.recordings == recorded + 1
    }
    XCTAssertTrue(
      layer(host.layer, ids[0]) === native,
      "Unchanged CALayer must survive the actual SQLite metadata/page refresh")
    XCTAssertEqual(
      host.metrics.recordings, recorded + 1, "Only the added short message requires recording")
    host.close()
    try await h.close()
  }

}

@MainActor final class NativeBubbleCompositionTests: XCTestCase {
  private struct Input: Decodable {
    let chatId: Int64
    let rows: [Row]
  }
  private struct Row: Decodable {
    let messageId: Int64, sortKey: Int64, savedAtMs: Int64
    let text: String
  }
  // Читаем рисунок сцены как четыре байта на пиксель без различий в цветовом пространстве. Данные
  // нужны для сверки с отдельным образцом.
  private func pixels(_ image: CGImage) throws -> [UInt8] {
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
  // Запускаем общее сравнение и требуем, чтобы фон закрашивался системным слоем. Пиксели текста
  // при этом сверяются с прежним рисунком.
  func testTextBubbleUsesNativeFillAndRetainsSharpInkWithOriginalPixels() async throws {
    try await compare(requiresNativeFill: true)
  }
  // Сверяем текущие слои и пиксели реальных сообщений с отдельным эталоном. Так можно заметить
  // отличие и у сообщений, для которых требуется обычный полный рисунок.
  func testFrozenReferenceMatchesNativeScenePipeline() async throws {
    try await compare(requiresNativeFill: false)
  }
  // Готовим сохранённые сообщения двумя способами и сравниваем фон, скругление и буквы. Учитываем
  // размещение буфера в целых пикселях, чтобы разное начало координат не исказило сверку.
  private func compare(requiresNativeFill: Bool) async throws {
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/text-raster-samples.json")
    let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: fixture))
    XCTAssertEqual(input.chatId, 1352)
    var comparisons = 0, largestMean = 0.0, largestChanged = 0.0
    for scale in [1, 2, 3] {
      for direction in [MessageDirection.incoming, .outgoing] {
        for row in input.rows {
          let message = Message(
            id: row.messageId, chatID: input.chatId,
            order: OrderKey(sortKey: row.sortKey, messageID: row.messageId), direction: direction,
            savedAtMs: row.savedAtMs, kind: .text, text: row.text, caption: "", replyToID: nil,
            revision: 1, attachments: [])
          let prepared = PreparedText(
            message: message,
            key: TextLayoutKey(
              messageID: message.id, revision: 1, width: 280, fontSize: 18, scale: scale))
          defer { prepared.close() }
          for part in Set([0, prepared.blocks.count / 2, prepared.blocks.count - 1]).sorted() {
            let size = CGSize(width: prepared.width, height: prepared.blocks[part].height),
              root = CALayer(), scene = RetainedChatScene(container: root)
            root.bounds = CGRect(origin: .zero, size: size)
            let fragment = SceneFragment(prepared: prepared, part: part, frame: root.bounds)
            scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [fragment]))
            defer { scene.close() }
            let node = try XCTUnwrap(root.sublayers?.first as? MessageLayer)
            let fill = (direction == .incoming ? UIColor.white : KandinskyPalette.outgoing).cgColor
            if requiresNativeFill && prepared.nativeTextBubbleColor != nil {
              XCTAssertEqual(
                node.backgroundColor, fill,
                "Uniform text bubble fill belongs to the already retained native message, not another full bitmap paint"
              )
              guard node.backgroundColor == fill else { return }
              var corners: CACornerMask = []
              if part == 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
              if part == prepared.blocks.count - 1 {
                corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
              }
              XCTAssertEqual(node.maskedCorners, corners)
              XCTAssertEqual(node.cornerRadius, 14)
            } else if requiresNativeFill {
              XCTAssertNil(
                node.backgroundColor, "Multipart text retains the frozen bitmap silhouette")
              XCTAssertEqual(node.cornerRadius, 0)
            }
            let end = Date().addingTimeInterval(3)
            while node.contents == nil, Date() < end {
              try await Task.sleep(nanoseconds: 2_000_000)
            }
            let contents = try XCTUnwrap(node.contents), ink = contents as! CGImage,
              bytes = try pixels(ink)
            if requiresNativeFill && prepared.nativeTextBubbleColor != nil && part == 0 {
              XCTAssertEqual(
                bytes[(ink.width * min(1, ink.height - 1) + ink.width / 2) * 4 + 3], 0,
                "The empty upper text inset must stay transparent in the sharp ink bitmap")
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = CGFloat(scale)
            format.opaque = false
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let bitmapWidth = Int(ceil(size.width * CGFloat(scale))),
              bitmapHeight = Int(ceil(size.height * CGFloat(scale)))
            let referenceContext = try XCTUnwrap(
              CGContext(
                data: nil, width: bitmapWidth, height: bitmapHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            referenceContext.translateBy(x: 0, y: CGFloat(bitmapHeight))
            referenceContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            prepared.draw(part: part, in: referenceContext)
            let referenceLayer = CALayer()
            referenceLayer.frame = fragment.frame
            referenceLayer.contentsScale = CGFloat(scale)
            referenceLayer.contents = try XCTUnwrap(referenceContext.makeImage())
            let referenceImage = renderer.image { referenceLayer.render(in: $0.cgContext) },
              actualImage = renderer.image { root.render(in: $0.cgContext) }
            let reference = try pixels(XCTUnwrap(referenceImage.cgImage)),
              actual = try pixels(XCTUnwrap(actualImage.cgImage))
            XCTAssertEqual(actual.count, reference.count)
            var error = 0, changed = 0
            for index in actual.indices {
              let delta = abs(Int(actual[index]) - Int(reference[index]))
              error += delta
              if delta > 16 { changed += 1 }
            }
            let mean = Double(error) / Double(actual.count),
              fraction = Double(changed) / Double(actual.count) * 100
            do {
              var cornerChanges = 0, interiorChanges = 0, alphaChanges = 0
              for pixel in 0..<(actual.count / 4) {
                let large = (0..<4).contains {
                  abs(Int(actual[pixel * 4 + $0]) - Int(reference[pixel * 4 + $0])) > 16
                }
                if large {
                  let x = pixel % ink.width, y = pixel / ink.width, r = 14 * scale
                  if (x < r || x >= ink.width - r) && (y < r || y >= ink.height - r) {
                    cornerChanges += 1
                  } else {
                    interiorChanges += 1
                  }
                }
                if actual[pixel * 4 + 3] != reference[pixel * 4 + 3] { alphaChanges += 1 }
              }
              XCTAssertLessThanOrEqual(
                Double(interiorChanges) / Double(actual.count / 4) * 100, 0.20,
                "Text and the flat interior must keep the reference pixels")
              print(
                """
                KANDINSKY_BUBBLE_PIXEL_DIAG id=\(row.messageId) part=\(part) scale=\(scale)\
                 direction=\(direction) mean=\(mean) cornerLargePixels=\(cornerChanges)\
                 noncornerLargePixels=\(interiorChanges) alphaChangedPixels=\(alphaChanges)
                """
              )
            }
            if row.messageId == 10041, part == 0 {
              for (label, image) in [("frozen", referenceImage), ("native", actualImage)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "bubble-\(label)-\(direction)-\(scale)x"
                attachment.lifetime = .keepAlways
                add(attachment)
              }
            }
            largestMean = max(largestMean, mean)
            largestChanged = max(largestChanged, fraction)
            XCTAssertLessThanOrEqual(
              mean, 0.35, "Native composition must preserve the original sharp text and silhouette")

            let identity = node.contents as AnyObject?, recordings = scene.metrics.recordings
            for y in 1...60 {
              scene.apply(
                SceneSnapshot(
                  ticket: scene.ticket,
                  fragments: [
                    SceneFragment(
                      prepared: prepared, part: part,
                      frame: fragment.frame.offsetBy(dx: 0, dy: CGFloat(y)))
                  ]))
            }
            XCTAssertTrue(identity === (node.contents as AnyObject?))
            XCTAssertEqual(scene.metrics.recordings, recordings)
            XCTAssertEqual(
              root.sublayers?.count, 1,
              "One existing retained message owner; no view per glyph or background")
            XCTAssertTrue((node.sublayers ?? []).isEmpty)
            scene.close()
            XCTAssertNil(node.contents)
            comparisons += 1
          }
        }
      }
    }
    print(
      """
      KANDINSKY_NATIVE_BUBBLE_COMPOSITION comparisons=\(comparisons) largestMeanRGBAError=\(largestMean) \
      largestChangedChannelsPercent=\(largestChanged)
      """
    )
    XCTAssertGreaterThanOrEqual(comparisons, 30)
  }
}
