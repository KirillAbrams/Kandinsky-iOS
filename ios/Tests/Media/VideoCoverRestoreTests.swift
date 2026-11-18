// Проверяет возврат к чёткому кадру ролика после ухода с экрана и очистки памяти. Сверяет, что
// более свежий кадр и удаление побеждают запоздалые ответы.

import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class VideoCoverRestoreTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let key: VideoPlaybackKey
    let image: CGImage
    let attachment: Attachment
    // Создаёт другой ключ показа с тем же вложением и указанным номером сообщения. Проверка может
    // заполнить хранилище разными кадрами одного исходника.
    func keyWithID(_ id: Int64) -> VideoPlaybackKey {
      VideoPlaybackKey(messageID: id, attachment: attachment)
    }
    // Удаляет временную папку опыта. Готовые кадры из одной проверки не должны попасть в другую.
    func close() { try? FileManager.default.removeItem(at: root) }
  }
  // Читает настоящее пробное изображение и готовит папку, вложение и ключ. Так восстановление
  // проверяется на известных пикселях.
  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    )
    .appendingPathComponent("real-media/backend-824d66cce0d64409ad4888a13792c7d4.jpg")
    let photo = try XCTUnwrap(UIImage(contentsOfFile: source.path))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let image = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        .image { _ in photo.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64)) }.cgImage)
    let attachment = Attachment(
      id: "cover", relativePath: "remote/cover.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 3000,
      thumbnailKey: "cover")
    let key = VideoPlaybackKey(messageID: 81001, attachment: attachment)
    let disk = VideoCoverDiskCache(root: root)
    try disk.store(image, key: key)
    disk.close()
    return Fixture(root: root, key: key, image: image, attachment: attachment)
  }
  // Получает байты рисунка для сравнения. Два разных объекта считаются одним кадром только при
  // совпадении содержимого.
  private func pixels(_ image: CGImage?) -> Data? {
    guard let data = image?.dataProvider?.data else { return nil }
    return data as Data
  }
  // Даёт фоновой очистке время и требует нулевой счёт памяти. Иначе старое изображение осталось
  // бы занятым после закрытия.
  private func awaitReleased(_ budget: ImageByteBudget) async throws {
    for _ in 0..<300 where budget.bytes != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(budget.bytes, 0, "Obsolete pixels must release byte ownership")
  }

  // Оставляет в памяти обычную картинку и восстанавливает чёткий кадр с диска. Проверяет
  // отсутствие мелькания картинки и замену правильным остановленным кадром.
  func testReturningVideoPrefersTheDiskFrameEvenWithAPosterInMemory() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let slot = MediaImageSlot(store: media)
    let example = try fixture()
    defer { example.close(); slot.close(); media.close() }

    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-00.mp4")
    let draft = try await media.stage(sourceURL: source, mime: "video/mp4")
    let attachment = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.id)
    let key = VideoPlaybackKey(messageID: 42, attachment: attachment)
    let disk = VideoCoverDiskCache(root: h.store.root)
    try disk.store(example.image, key: key)
    disk.close()

    let poster: PreparedImage = try await withCheckedThrowingContinuation { done in
      media.thumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: 128), ticket: 0) {
        _, result in done.resume(with: result)
      }
    }
    defer { poster.close() }
    slot.bind(attachment, frame: CGRect(x: 0, y: 0, width: 160, height: 90), maxPixel: 128,
      kind: .video, playbackKey: key)
    slot.seed(try XCTUnwrap(poster.retained()))
    let first = slot.preview()
    XCTAssertNil(first, "A poster ready in memory must not flash during disk restoration")
    first?.close()

    for _ in 0..<200 where !slot.hasSharpFrame { try await Task.sleep(nanoseconds: 10_000_000) }
    let restored = slot.preview()
    XCTAssertEqual(pixels(restored?.image), pixels(example.image))
    restored?.close()

    // При короткой прокрутке сохраняется тот же слой. Следующая пауза заменяет в нём старый кадр.
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let paused = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
      format: format).image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      }.cgImage)
    media.videoPlayback.rememberFrame(key: key, generation: media.videoPlayback.generation,
      width: paused.width, height: paused.height) { _, _ in paused }
    XCTAssertTrue(slot.showSavedPlaybackFrame(for: key))
    let updated = slot.preview()
    XCTAssertEqual(pixels(updated?.image), pixels(paused))
    updated?.close()
    slot.close(); media.close(); try await h.close()
  }

  // Удерживает чтение остановленного кадра вне потока экрана и сохраняет более свежий прямо
  // сейчас. Старое завершение не должно заменить новое или удержать лишнюю память.
  func testPausedCoverRendersOffMainAndNewerImmediateCoverWins() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget)
    let resume = DispatchSemaphore(value: 0)
    defer {
      resume.signal()
      cache.close()
      fixture.close()
    }
    let started = expectation(description: "background render began")
    cache.enqueueFrame(key: fixture.key, generation: cache.generation,
      width: 64, height: 64, sourceBytes: 16_384) { _, _ in
      XCTAssertFalse(Thread.isMainThread)
      started.fulfill()
      _ = resume.wait(timeout: .now() + 4)
      return fixture.image
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertNil(cache.frame(fixture.key))
    XCTAssertGreaterThanOrEqual(budget.bytes, 16_384)
    let latest = try XCTUnwrap(fixture.image.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
    cache.rememberFrame(key: fixture.key, generation: cache.generation, width: 32, height: 32) {
      _, _ in latest
    }
    resume.signal()
    let latestBytes = latest.bytesPerRow * latest.height
    for _ in 0..<150 where budget.bytes != latestBytes { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(budget.bytes, latestBytes)
    let retained = try XCTUnwrap(cache.frame(fixture.key))
    XCTAssertTrue(retained.image === latest)
    retained.close()
    cache.clearFrames()
    try await awaitReleased(budget)
  }

  // Очищает хранилище при одной выполняемой и одной ожидающей подготовке. Ожидающая отдаёт память
  // сразу, а после выхода первой обе копии отсутствуют.
  func testClearingDuringPausedCoverRenderCannotRestoreTheCover() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget)
    let resume = DispatchSemaphore(value: 0)
    defer {
      resume.signal()
      cache.close()
      fixture.close()
    }
    let started = expectation(description: "background render began")
    cache.enqueueFrame(key: fixture.key, generation: cache.generation,
      width: 64, height: 64, sourceBytes: 16_384) { _, _ in
      started.fulfill()
      _ = resume.wait(timeout: .now() + 4)
      return fixture.image
    }
    await fulfillment(of: [started], timeout: 2)
    let runningBytes = budget.bytes
    let queuedKey = fixture.keyWithID(81002)
    cache.enqueueFrame(key: queuedKey, generation: cache.generation,
      width: 64, height: 64, sourceBytes: 16_384) { _, _ in
      XCTFail("A cancelled queued capture must never start")
      return fixture.image
    }
    XCTAssertGreaterThan(budget.bytes, runningBytes)
    cache.clearFrames()
    XCTAssertEqual(budget.bytes, runningBytes, "Cancellation releases the queued pixels immediately")
    resume.signal()
    try await awaitReleased(budget)
    XCTAssertNil(cache.frame(fixture.key))
    XCTAssertNil(cache.frame(queuedKey))
  }

  // Запускает два восстановления одной дисковой копии и сверяет общий рисунок и исходные пиксели.
  // Затем проверяет, что третий запрос может взять этот кадр из памяти.
  func testConcurrentRestoresSharePixelsAndPromoteThemToMemory() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    var frames: [PreparedImage] = []
    var errors: [Error] = []
    defer {
      frames.forEach { $0.close() }
      cache.close()
      fixture.close()
    }
    let delivered = expectation(description: "two owners")
    delivered.expectedFulfillmentCount = 2
    for _ in 0..<2 {
      _ = cache.restoreCover(fixture.key) { result in
        switch result {
        case .success(let frame): frames.append(frame)
        case .failure(let error): errors.append(error)
        }
        delivered.fulfill()
      }
    }
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertTrue(errors.isEmpty, "Valid real cover must restore")
    XCTAssertEqual(frames.count, 2)
    guard frames.count == 2 else { return }
    XCTAssertTrue(frames[0].image === frames[1].image, "Owners share one restored image")
    XCTAssertEqual(pixels(frames[0].image), pixels(fixture.image))
    try FileManager.default.removeItem(
      at: fixture.root.appendingPathComponent("media/video-covers"))
    let cached = try XCTUnwrap(cache.cover(fixture.key))
    XCTAssertTrue(cached.image === frames[0].image, "Restored pixels must populate RAM")
    cached.close()
    frames.forEach { $0.close() }
    cache.close()
    try await awaitReleased(budget)
  }

  // Очищает кадры до выдачи ожидающему экрану. Запрос не публикует старый результат и освобождает
  // подготовленные байты.
  func testClearBeforeDeliveryCancelsPublicationAndReleasesPixels() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    defer {
      cache.close()
      fixture.close()
    }
    let delivered = expectation(description: "cancelled owner")
    var published = false
    _ = cache.restoreCover(fixture.key) { result in
      if case .success(let frame) = result {
        published = true
        frame.close()
      }
      delivered.fulfill()
    }
    cache.clearFrames()
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertFalse(published, "An obsolete generation must not publish")
    XCTAssertNil(cache.cover(fixture.key))
    try await awaitReleased(budget)
  }

  // Задерживает чтение старой копии и сохраняет свежий отличимый кадр. После завершения диска в
  // памяти остаётся более свежий результат.
  func testDiskCompletionDoesNotReplaceANewerCapturedFrame() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let alternate = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        .image { context in
          context.cgContext.translateBy(x: 64, y: 64)
          context.cgContext.rotate(by: .pi)
          UIImage(cgImage: fixture.image).draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }.cgImage)
    XCTAssertNotEqual(
      pixels(alternate), pixels(fixture.image), "Real fixture distinguishes old and new")
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    var result: PreparedImage?
    defer {
      result?.close()
      cache.close()
      fixture.close()
    }
    let delivered = expectation(description: "pending read")
    _ = cache.restoreCover(fixture.key) { value in
      result = try? value.get()
      delivered.fulfill()
    }
    let until = ProcessInfo.processInfo.systemUptime + 2
    while budget.bytes == 0 && ProcessInfo.processInfo.systemUptime < until {
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTAssertGreaterThan(budget.bytes, 0, "Reader owns the old file before the newer capture")
    cache.rememberFrame(key: fixture.key, generation: cache.generation, width: 64, height: 64) {
      _, _ in alternate
    }
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertEqual(
      pixels(result?.image), pixels(alternate), "Late disk pixels cannot replace a fresh capture")
    let cached = cache.cover(fixture.key)
    XCTAssertEqual(pixels(cached?.image), pixels(alternate))
    cached?.close()
    result?.close()
    cache.close()
    try await awaitReleased(budget)
  }

  // Начинает чтение и отзывает исходник до выдачи. Ни экран, ни хранилище не должны получить
  // отозванный кадр.
  func testDeletionAfterReadStartsCannotPublishRevokedCover() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    defer {
      cache.close()
      fixture.close()
    }
    let delivered = expectation(description: "revoked read")
    var published = false
    _ = cache.restoreCover(fixture.key) { result in
      if case .success(let frame) = result {
        published = true
        frame.close()
      }
      delivered.fulfill()
    }
    let until = ProcessInfo.processInfo.systemUptime + 2
    while budget.bytes == 0 && ProcessInfo.processInfo.systemUptime < until {
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTAssertGreaterThan(budget.bytes, 0, "Reader opens the cover before revocation")
    try VideoCoverDiskCache.revoke(root: fixture.root, relativePath: fixture.key.relativePath)
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertFalse(published, "A revoked cover must not escape a pending read")
    XCTAssertNil(cache.cover(fixture.key))
    cache.close()
    try await awaitReleased(budget)
  }

  // После выдачи кадра первому получателю очищает хранилище. Второй получатель должен проверить
  // действительность заново и уже не получить устаревшие пиксели.
  func testFirstDeliveryClearingCacheCancelsOtherPendingOwners() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    defer {
      cache.close()
      fixture.close()
    }
    let delivered = expectation(description: "both owners complete")
    delivered.expectedFulfillmentCount = 2
    var deliveries = 0
    var firstSucceeded = false
    var staleSucceeded = false
    for _ in 0..<2 {
      _ = cache.restoreCover(fixture.key) { result in
        let first = deliveries == 0
        deliveries += 1
        if case .success(let frame) = result {
          if first { firstSucceeded = true } else { staleSucceeded = true }
          frame.close()
        }
        if first { cache.clearFrames() }
        delivered.fulfill()
      }
    }
    await fulfillment(of: [delivered], timeout: 3)
    XCTAssertTrue(firstSucceeded)
    XCTAssertFalse(staleSucceeded, "Later owners must recheck the generation at delivery")
    cache.close()
    try await awaitReleased(budget)
  }

  // Сохраняет больше четырёх небольших кадров в прежнем пределе памяти, затем добавляет большие.
  // Проверяет вытеснение раннего кадра и сохранение заданного предела байтов.
  func testSmallCoversSurviveBeyondFourWithoutIncreasingPreviousByteCeiling() throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget)
    defer {
      cache.close()
      fixture.close()
    }
    let attachment = Attachment(
      id: "cover", relativePath: "remote/cover.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 3000,
      thumbnailKey: "cover")
    // Делает отдельный ключ для каждого номера в опыте с разными размерами. Так добавление нового
    // кадра проверяет рост и вытеснение вместо замены одной записи.
    func key(_ id: Int64) -> VideoPlaybackKey {
      VideoPlaybackKey(messageID: id, attachment: attachment)
    }
    for id in 1...8 {
      cache.rememberFrame(key: key(Int64(id)), generation: cache.generation, width: 64, height: 64)
      { _, _ in fixture.image }
    }
    let first = cache.frame(key(1))
    XCTAssertNotNil(first, "Eight small covers fit the existing16MiB budget")
    first?.close()
    cache.clearFrames()
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let large = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format)
        .image { _ in
          UIImage(cgImage: fixture.image).draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }.cgImage)
    for id in 1...5 {
      cache.rememberFrame(
        key: key(Int64(id)), generation: cache.generation, width: 1024, height: 1024
      ) { _, _ in large }
    }
    XCTAssertLessThanOrEqual(budget.bytes, 16 * 1024 * 1024)
    XCTAssertNil(cache.frame(key(1)))
    cache.close()
    XCTAssertEqual(budget.bytes, 0)
  }

  // Вытесняет кадр из памяти и ставит раннюю подготовку перед возвращением ролика. Новый поиск
  // получает те же пиксели сразу после подготовки.
  func testPreparationRestoresAnEvictedCoverBeforeItsNextVisibleLookup() async throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    let cache = VideoPlaybackCache(budget: budget, root: fixture.root)
    defer {
      cache.close()
      fixture.close()
    }
    cache.rememberFrame(key: fixture.key, generation: cache.generation, width: 64, height: 64) {
      _, _ in fixture.image
    }
    for id in 1...65 {
      cache.rememberFrame(key: fixture.keyWithID(Int64(id)), generation: cache.generation,
        width: 64, height: 64) { _, _ in fixture.image }
    }
    XCTAssertNil(cache.cover(fixture.key))
    cache.prepareCovers([fixture.key])
    var prepared = false
    for _ in 0..<300 {
      if let frame = cache.cover(fixture.key) {
        frame.close()
        prepared = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(prepared, "An approaching video must prepare its disk cover")
    try FileManager.default.removeItem(
      at: fixture.root.appendingPathComponent("media/video-covers"))
    let ready = try XCTUnwrap(cache.cover(fixture.key))
    XCTAssertEqual(pixels(ready.image), pixels(fixture.image))
    ready.close()
    cache.prepareCovers([])
    cache.close()
    try await awaitReleased(budget)
  }

  // Заполняет ограниченный набор описаний, а затем проверяет пониженный предел памяти. Старые
  // копии освобождаются, даже если ограничение задано числом записей или байтами.
  func testMetadataAndReducedMemoryBudgetBothBoundRetainedCovers() throws {
    let fixture = try fixture()
    let budget = ImageByteBudget()
    budget.limit = 24 * 1024 * 1024
    let cache = VideoPlaybackCache(budget: budget)
    defer {
      cache.close()
      fixture.close()
    }
    for id in 1...65 {
      cache.rememberFrame(
        key: fixture.keyWithID(Int64(id)), generation: cache.generation,
        width: 64, height: 64
      ) { _, _ in fixture.image }
    }
    XCTAssertNil(cache.cover(fixture.keyWithID(1)))
    let recent = try XCTUnwrap(cache.cover(fixture.keyWithID(65)))
    recent.close()
    cache.clearFrames()
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let large = try XCTUnwrap(
      UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024), format: format)
        .image { _ in
          UIImage(cgImage: fixture.image).draw(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }.cgImage)
    for id in 1...3 {
      cache.rememberFrame(
        key: fixture.keyWithID(Int64(id)), generation: cache.generation,
        width: 1024, height: 1024
      ) { _, _ in large }
    }
    XCTAssertLessThanOrEqual(budget.bytes, 8 * 1024 * 1024)
    XCTAssertNil(cache.cover(fixture.keyWithID(1)))
    cache.close()
    XCTAssertEqual(budget.bytes, 0)
  }
}
