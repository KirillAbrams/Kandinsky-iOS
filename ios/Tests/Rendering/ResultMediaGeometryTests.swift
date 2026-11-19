// Проверяем размеры карточек генерации, фото, видео и подписей. Сверяем прозрачность и положение
// кнопок по координатам и по нарисованным пикселям.

import XCTest
import UIKit
import CoreText
@testable import Kandinsky
final class ResultMediaGeometryTests: XCTestCase {
  // Проверяем процент одиночного задания и действия для разных исходов. Заблокированный результат
  // не должен предлагать запрещённый повтор, а отменённый должен показать свой статус.
  func testSingleGenerationKeepsItsProgressAndOnlyOffersAllowedRetries() throws {
    // Собираем одно задание с нужной стадией, процентом и причиной ошибки. Готовая карточка
    // позволяет проверить правила кнопок и рисунок без запуска генерации.
    func prepare(
      _ stage: StudioGeneration.Stage, error: String? = nil, moderated: Bool? = nil,
      progress: Int? = nil
    ) -> PreparedText {
      let generation = StudioGeneration(
        stage: stage, model: "video", aspect: "invalid", startedAtMs: nil, error: error,
        moderated: moderated, progress: progress)
      let row = Message(
        id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
        savedAtMs: 0, kind: .text, text: "", caption: "", replyToID: nil,
        revision: 1, attachments: [], studioGeneration: generation)
      return PreparedText(
        message: row,
        key: TextLayoutKey(messageID: 1, revision: 1, width: 300, fontSize: 17, scale: 1))
    }
    let running = prepare(.running, progress: 41)
    let advanced = prepare(.running, progress: 72)
    let failed = prepare(.failed)
    let blocked = prepare(.failed, error: "Генерация заблокирована после проверки", moderated: true)
    let cancelled = prepare(.cancelled, error: "Не показывать")
    defer { [running, advanced, failed, blocked, cancelled].forEach { $0.close() } }

    let runningCard = try XCTUnwrap(running.generationCard)
    XCTAssertEqual(runningCard.runningCells.count, 1)
    let runningCell = try XCTUnwrap(runningCard.runningCells.first)
    XCTAssertEqual(runningCell.slot.id, "single")
    XCTAssertEqual(runningCell.slot.progress, 41)
    XCTAssertEqual(runningCard.imageFrame, runningCell.frame)
    XCTAssertEqual(runningCell.frame.height, 250, accuracy: 0.01)
    XCTAssertTrue(runningCard.sameStaticInk(as: try XCTUnwrap(advanced.generationCard)))
    XCTAssertTrue(runningCard.controls.isEmpty)
    XCTAssertEqual(StudioGenerationCard.progressLabel(.running, 100), "Создаём")

    let failureCard = try XCTUnwrap(failed.generationCard)
    XCTAssertEqual(failureCard.status, "Не удалось создать. Попробуйте ещё раз.")
    XCTAssertNil(failureCard.imageFrame)
    XCTAssertTrue(failureCard.runningCells.isEmpty)
    XCTAssertEqual(failureCard.controls.map(\.action), [.retry])
    let retry = try XCTUnwrap(failureCard.controls.first)
    XCTAssertGreaterThanOrEqual(retry.frame.minY, failureCard.statusFrame.maxY)
    XCTAssertLessThan(retry.frame.maxY, failureCard.height)

    let blockedCard = try XCTUnwrap(blocked.generationCard)
    XCTAssertEqual(blockedCard.status, "Генерация заблокирована после проверки")
    XCTAssertTrue(blockedCard.controls.isEmpty)
    XCTAssertEqual(cancelled.generationCard?.status, "Генерация отменена")

    let (width, _, pixels) = raster(failed)
    XCTAssertEqual(pixels[3], 0)
    let center = Int(retry.frame.midY) * width + Int(retry.frame.midX)
    XCTAssertEqual(pixels[center * 4 + 3], 255)
  }

  // Подставляем результаты по мере готовности в группу из четырёх фото или видео. Ячейки и высота
  // карточки должны сохраняться и при ошибке, и при завершении.
  func testStudioBatchKeepsFourCellsWhenTheThirdFileArrives() throws {
    for (model, kind, mime) in [
      ("image", MessageKind.photo, "image/png"), ("video", .video, "video/mp4")
    ] {
      let ids = ["first", "second", "third", "fourth"]
      let waiting = ids.map {
        StudioGeneration.Slot(id: $0, status: .queued, blobId: nil, progress: nil)
      }
      var partial = waiting
      partial[0] = StudioGeneration.Slot(id: ids[0], status: .running, blobId: nil, progress: 37)
      partial[2] = StudioGeneration.Slot(
        id: ids[2], status: .succeeded, blobId: "third-file", progress: 100)
      let attachment = Attachment(
        id: "net-1-result-third-file", relativePath: "remote/third-file", mime: mime, byteSize: 100,
        rawWidth: 512, rawHeight: 512, orientation: 1, durationMs: nil, thumbnailKey: "third-file")
      // Готовим одно представление группы из заданных состояний и уже доступных файлов. Тот же
      // расчёт размеров позволяет сравнить разные стадии одной группы.
      func prepare(
        _ slots: [StudioGeneration.Slot], _ media: [Attachment], aspect: String = "1:1"
      ) -> PreparedText {
        let state = StudioGeneration(
          stage: slots.allSatisfy { $0.status == .succeeded } ? .succeeded : .running, model: model,
          aspect: aspect, startedAtMs: nil, error: nil, slots: slots)
        let row = Message(
          id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
          savedAtMs: 0, kind: media.isEmpty ? .text : kind, text: "", caption: "", replyToID: nil,
          revision: 1, attachments: media, studioGeneration: state)
        return PreparedText(
          message: row,
          key: TextLayoutKey(messageID: 1, revision: 1, width: 300, fontSize: 17, scale: 2))
      }
      let initial = prepare(waiting, []), updated = prepare(partial, [attachment])
      defer {
        initial.close()
        updated.close()
      }
      let before = try XCTUnwrap(initial.generationCard),
        after = try XCTUnwrap(updated.generationCard)
      XCTAssertEqual(before.cells.count, 4)
      XCTAssertTrue(before.controls.isEmpty, "Active generation actions belong in the composer")
      XCTAssertEqual(before.height, try XCTUnwrap(before.imageFrame).maxY + 2)
      XCTAssertEqual(
        before.cells.map { $0.frame.minY },
        [
          before.cells[0].frame.minY, before.cells[0].frame.minY, before.cells[2].frame.minY,
          before.cells[2].frame.minY
        ])
      XCTAssertEqual(before.cells[0].frame.width, before.cells[3].frame.width, accuracy: 1)
      XCTAssertEqual(before.cells.map(\.frame), after.cells.map(\.frame))
      XCTAssertEqual(updated.mediaItemRects, [after.cells[2].frame])
      XCTAssertTrue(initial.mediaItemRects.isEmpty)
      XCTAssertNil(updated.mediaOnlyBackground)
      XCTAssertEqual(
        StudioGenerationCard.progressLabel(
          after.cells[0].slot.status, after.cells[0].slot.progress), "37%")
      var advanced = partial
      advanced[0] = StudioGeneration.Slot(id: ids[0], status: .running, blobId: nil, progress: 61)
      let ticking = prepare(advanced, [attachment])
      defer { ticking.close() }
      XCTAssertTrue(try XCTUnwrap(ticking.generationCard).sameStaticInk(as: after))

      advanced[1] = StudioGeneration.Slot(id: ids[1], status: .failed, blobId: nil, progress: nil)
      let interrupted = prepare(advanced, [attachment])
      defer { interrupted.close() }
      let failed = try XCTUnwrap(interrupted.generationCard)
      XCTAssertEqual(failed.retryCells.map { $0.slot.id }, [ids[1]])
      XCTAssertEqual(failed.cells.map(\.frame), before.cells.map(\.frame))
      XCTAssertEqual(interrupted.height, initial.height)
      var blockedSlots = advanced
      blockedSlots[1] = .init(
        id: ids[1], status: .failed, blobId: nil, progress: nil, moderated: true)
      let blocked = prepare(blockedSlots, [attachment])
      defer { blocked.close() }
      XCTAssertTrue(try XCTUnwrap(blocked.generationCard).retryCells.isEmpty)
      let button = try XCTUnwrap(failed.retryCells.first).frame
      let (width, _, withRetry) = raster(interrupted)
      let (blockedWidth, _, withoutRetry) = raster(blocked)
      XCTAssertEqual(width, blockedWidth)
      let pixel = (Int(button.midY + 12) * width + Int(button.midX - 28)) * 4
      XCTAssertEqual(withRetry[pixel + 3], 255)
      XCTAssertNotEqual(withRetry[pixel ..< pixel + 4], withoutRetry[pixel ..< pixel + 4])

      let singlePortrait = prepare([waiting[0]], [], aspect: "9:16")
      defer { singlePortrait.close() }
      let portraitFrame = try XCTUnwrap(singlePortrait.generationCard?.cells.first?.frame)
      XCTAssertEqual(portraitFrame.height, model == "video" ? 360 : 380, accuracy: 0.01)
      XCTAssertEqual(portraitFrame.width / portraitFrame.height, 9.0 / 16, accuracy: 0.01)

      let allMedia = ids.map { id in
        Attachment(
          id: "net-1-result-" + id, relativePath: "remote/" + id, mime: mime, byteSize: 100,
          rawWidth: 512, rawHeight: 512, orientation: 1, durationMs: nil, thumbnailKey: id)
      }
      let finished = prepare(
        ids.map { .init(id: $0, status: .succeeded, blobId: $0, progress: nil) }, allMedia)
      defer { finished.close() }
      XCTAssertEqual(finished.mediaItemRects, before.cells.map(\.frame))
      XCTAssertEqual(finished.height, initial.height)
    }
  }
  // Сравниваем одиночный цветной знак и обычный смешанный текст. Первый получает крупный размер и
  // прозрачный фон, второй сохраняет обычную геометрию сообщения.
  func testEmojiOnlyUsesLargeTransparentMessageAndMixedTextKeepsItsBubble() {
    // Создаём входящее сообщение с нужной строкой и фиксированными настройками шрифта. Так
    // меняется только состав текста, который влияет на оформление.
    func prepared(_ text: String) -> PreparedText {
      let row = Message(
        id: 7, chatID: 2, order: OrderKey(sortKey: 1, messageID: 7), direction: .incoming,
        savedAtMs: 0, kind: .text, text: text, caption: "", replyToID: nil, revision: 1,
        attachments: [])
      return PreparedText(
        message: row,
        key: TextLayoutKey(messageID: 7, revision: 1, width: 304, fontSize: 17, scale: 1))
    }
    for text in ["😀", "1️⃣", "👨‍👩‍👧‍👦", "🇷🇺"] {
      let p = prepared(text)
      defer { p.close() }
      XCTAssertGreaterThan(
        p.height, 100, "A single emoji uses the94pt source reference size, including joined emoji")
      let (w, h, bytes) = raster(p)
      XCTAssertEqual(
        bytes[((h - 10) * w + 10) * 4 + 3], 0,
        "Emoji-only messages have no rectangular card below the glyph")
    }
    for text in ["Привет 😀", "1", "©"] {
      let p = prepared(text)
      defer { p.close() }
      XCTAssertLessThan(
        p.height, 80, "Ordinary text and text-presentation symbols retain normal layout")
    }
  }
  // Проверяем ширину наклейки и отсутствие скругления и подложки. Прозрачный центр фонового
  // рисунка защищает от появления лишней карточки под наклейкой.
  func testStickerFitsReferenceEnvelopeWithoutPhotoCard() {
    let p = layout(.sticker, 512, 512)
    defer { p.close() }
    XCTAssertEqual(
      p.mediaRect!.width, 180, accuracy: 0.5,
      "A regular sticker fits the180pt source reference envelope")
    XCTAssertEqual(p.mediaCornerRadius, 0, "Sticker alpha must not be clipped like a photo")
    XCTAssertEqual(p.mediaOnlyBackground?.alpha, 0, "A sticker has no coloured photo card")
    let (w, h, bytes) = raster(p)
    XCTAssertEqual(
      bytes[(h / 2 * w + w / 2) * 4 + 3], 0,
      "Retained body pixels must remain transparent below the actual sticker")
  }
  // Создаём сообщение с вложением нужного вида, размера и ориентации. Ограничение ширины и
  // подпись можно задать отдельно для проверки крайних случаев.
  private func layout(
    _ kind: MessageKind, _ width: Int, _ height: Int, _ caption: String = "", orientation: Int = 1,
    bound: Int = 304
  ) -> PreparedText {
    let a = Attachment(
      id: "visual", relativePath: "seed/visual", mime: "image/jpeg", byteSize: 100, rawWidth: width,
      rawHeight: height, orientation: orientation, durationMs: 7000, thumbnailKey: "")
    let m = Message(
      id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .outgoing,
      savedAtMs: 0, kind: kind, text: "", caption: caption, replyToID: nil, revision: 1,
      attachments: [a])
    return PreparedText(
      message: m,
      key: TextLayoutKey(messageID: 1, revision: 1, width: bound, fontSize: 17, scale: 2))
  }
  // Проверяем, что круглое видео размещается в квадрате со стороной 212 точек. Иначе круг и его
  // подписи могли бы занять лишнее место.
  func testCompactTelegramRoundDiameter() {
    let p = layout(.round, 480, 480)
    defer { p.close() }
    XCTAssertEqual(p.mediaRect!.width, 212, accuracy: 0.5)
    XCTAssertEqual(p.mediaRect!.height, 212, accuracy: 0.5)
  }
  // Подставляем вертикальное фото и сверяем ширину и высоту после масштабирования. Так видна
  // ошибка, при которой фотография сжимается по одной оси.
  func testPortraitFitsImageEnvelopeWithoutSquashing() {
    let p = layout(.photo, 600, 900)
    defer { p.close() }
    XCTAssertEqual(p.mediaRect!.height, 380, accuracy: 0.5)
    XCTAssertEqual(p.mediaRect!.width, 253.333, accuracy: 0.5)
  }
  // Проверяем высоту участка под фото с короткой подписью. Форма не должна добавлять лишнюю
  // строку между подписью и временем.
  func testShortCaptionSharesStatusRow() {
    let p = layout(.photo, 1600, 900, "Привет")
    defer { p.close() }
    XCTAssertLessThanOrEqual(p.height - p.mediaRect!.maxY, 37)
  }
  // Рисуем круглое видео с подписью и проверяем прозрачный угол вне круга. Подпись не должна
  // включать прямоугольную карточку позади видео.
  func testRoundWithCaptionHasNoRectangularCard() {
    let p = layout(.round, 480, 480, "Подпись")
    defer { p.close() }
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: p.width, height: p.height))
    let image = renderer.image { p.draw(part: 0, in: $0.cgContext) }
    let cg = image.cgImage!
    let bytes = cg.dataProvider!.data! as Data
    XCTAssertEqual(
      bytes[40 * cg.bytesPerRow + 4 * 4 + 3], 0,
      "The round corner must stay transparent even when text is present")
  }
  // Передаём размеры горизонтального видео с признаком разворота. После разворота расчёт должен
  // применить пределы вертикального кадра.
  func testRotatedVideoUsesPortraitHeightEnvelope() {
    let p = layout(.video, 900, 600, orientation: 6)
    defer { p.close() }
    XCTAssertEqual(p.mediaRect!.width, 240, accuracy: 0.5)
    XCTAssertEqual(p.mediaRect!.height, 360, accuracy: 0.5)
  }
  // Подставляем длинную подпись, письмо справа налево и явный перенос. Проверяем, что последняя
  // строка остаётся внутри карточки с запасом снизу.
  func testCaptionLinesStayInsideCard() {
    for text in [
      String(repeating: "Длинная подпись ", count: 30), "مرحبا كيف حالك اليوم",
      "Строка\nВторая строка"
    ] {
      let p = layout(.photo, 600, 900, text)
      defer { p.close() }
      let rows = p.accessibleLines(from: 0, to: p.height, limit: 100)
      XCTAssertFalse(rows.isEmpty)
      XCTAssertLessThanOrEqual(rows.last!.frame.maxY, p.height - 5)
    }
  }

  // Рисуем подготовленный блок или только метки вложения в масштабе один к одному. Возвращаем
  // размеры и байты, чтобы проверять отдельные точки по координатам.
  private func raster(_ p: PreparedText, stamps: Bool = false) -> (Int, Int, [UInt8]) {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: p.width, height: p.height), format: format
    ).image { ctx in
      if stamps { p.drawMediaStamp(in: ctx.cgContext) } else { p.draw(part: 0, in: ctx.cgContext) }
    }.cgImage!
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { raw in
      let c = CGContext(
        data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)!
      c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, bytes)
  }

  // Проверяем пиксели длительности, времени и значка звука. Обе строки стоят внизу круга, а
  // значок остаётся сверху без лишней строки под видео.
  func testRoundReferencePillsShareBottomBaselineAndMuteSitsAtTop() {
    let p = layout(.round, 480, 480)
    defer { p.close() }
    let rect = p.mediaRect!
    let (w, _, bytes) = raster(p, stamps: true)
    // Читаем прозрачность пикселя по двум координатам. Проверка так различает нарисованную метку
    // и пустое место на той же высоте.
    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * w + x) * 4 + 3] }
    XCTAssertGreaterThan(
      alpha(6, Int(rect.maxY) - 12), 0, "Duration hugs the left edge of the circle")
    XCTAssertGreaterThan(
      alpha(w - 20, Int(rect.maxY) - 12), 0, "Send time shares the duration baseline")
    XCTAssertGreaterThan(
      alpha(Int(rect.midX), Int(rect.minY) + 12), 0, "Muted preview has a top speaker object")
    XCTAssertLessThanOrEqual(
      p.height - rect.maxY, 3, "Time is inside the message; no old extra status row")
  }

  // Перебираем пустые, отрицательные и очень вытянутые размеры на всех поворотах. Высота и ширина
  // должны оставаться конечными и помещать вложение внутрь сообщения.
  func testMediaGeometryPropertiesAcrossDimensionsAndOrientations() {
    for kind in [MessageKind.photo, .video, .gif, .round] {
      for bound in [80, 180, 304, 600] {
        for dims in [(0, 0), (-1, 80), (10000, 1), (1, 10000), (600, 900)] {
          for orientation in 1...8 {
            let p = layout(kind, dims.0, dims.1, orientation: orientation, bound: bound)
            defer { p.close() }
            let r = p.mediaRect!
            XCTAssertTrue(r.width.isFinite && r.height.isFinite && p.height.isFinite)
            XCTAssertGreaterThan(r.width, 0)
            XCTAssertGreaterThan(r.height, 0)
            XCTAssertLessThanOrEqual(p.width, CGFloat(bound))
            XCTAssertLessThanOrEqual(r.maxX, p.width)
            XCTAssertLessThanOrEqual(r.maxY, p.height)
          }
        }
      }
    }
  }

  // Считаем знаки времени для разных видов сообщений и исходов доставки. Проверяем, что
  // доставленное сообщение не получает отметку о чтении и входящее не получает исходящие отметки.
  func testDeliveredStampCannotImplyReadAcrossTextAndMedia() {
    let a = Attachment(
      id: "receipt", relativePath: "receipt", mime: "video/mp4", byteSize: 100, rawWidth: 480,
      rawHeight: 480, orientation: 1, durationMs: 7000, thumbnailKey: "")
    for kind in [MessageKind.text, .voice, .photo, .round] {
      for (state, glyphs) in [
        (MessageDelivery.accepted, 7), (.delivered, 7), (.read, 8), (.pending, 7), (.failed, 7)
      ] {
        var row = Message(
          id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .outgoing,
          savedAtMs: 0, kind: kind, text: "Receipt", caption: "", replyToID: nil, revision: 1,
          attachments: kind == .text ? [] : [a])
        row.delivery = state
        let p = PreparedText(
          message: row,
          key: TextLayoutKey(messageID: 1, revision: 1, width: 300, fontSize: 17, scale: 1))
        defer { p.close() }
        for field in ["stamp", "mediaStamp"] {
          let raw = try! XCTUnwrap(Mirror(reflecting: p).children.first { $0.label == field }).value
          let line = raw as! CTLine
          let expected =
            kind == .text && [.accepted, .delivered, .read].contains(state) ? 5 : glyphs
          XCTAssertEqual(
            CTLineGetGlyphCount(line), expected,
            "Generation prompt and legacy media keep their own timestamp rules, for \(kind)/\(state)/\(field)"
          )
        }
      }
    }
    var incoming = Message(
      id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
      savedAtMs: 0, kind: .text, text: "Incoming", caption: "", replyToID: nil, revision: 1,
      attachments: [])
    incoming.delivery = .read
    let p = PreparedText(
      message: incoming,
      key: TextLayoutKey(messageID: 1, revision: 1, width: 300, fontSize: 17, scale: 1))
    defer { p.close() }
    let line = Mirror(reflecting: p).children.first { $0.label == "stamp" }!.value as! CTLine
    XCTAssertEqual(CTLineGetGlyphCount(line), 5, "Incoming read messages have no outgoing checks")
  }

}
