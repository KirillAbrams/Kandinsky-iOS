// Проверки времени жизни изображений в ленте на айфоне. Они следят за чёткостью при возврате, за
// работой альбомов и за тем, чтобы прокрутка и клавиатура не заставляли повторно рисовать
// готовое.

import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class MediaImageLifetimeTests: XCTestCase {
  // Задерживаем чтение сохранённого фото и наблюдаем первый кадр после возврата. До готовности
  // чёткого изображения расплывчатая картинка не должна мелькнуть и передача с сервера не должна
  // начаться.
  func testLocalPhotoReturnPrefersSavedPixelsOverInlineBlur() async throws {
    final class LocalFile: MediaFileProvider, @unchecked Sendable {
      let url: URL
      let requested: XCTestExpectation
      let release = DispatchSemaphore(value: 0)
      // Запоминаем путь к местному фото и сигнал начала чтения. Проверка сможет удержать
      // получение файла в нужный момент.
      init(_ url: URL, _ requested: XCTestExpectation) {
        self.url = url
        self.requested = requested
      }
      // Сообщаем, что местный путь запрошен, и ждём разрешения чтения. Затем возвращаем
      // подготовленный файл, чтобы не смешивать местную работу с сетью.
      func cached(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws
        -> (URL, String)?
      {
        requested.fulfill()
        _ = release.wait(timeout: .now() + 4)
        return (url, "image/jpeg")
      }
      // Считаем обращение за сетевым файлом ошибкой проверки. Сохранённое фото должно открываться
      // через местный путь.
      func resolve(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws
        -> (URL, String)
      {
        XCTFail("A saved photo must not start a server request")
        throw MediaError.unavailable
      }
    }
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let slot = MediaImageSlot(store: media)
    let url = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: url, mime: "image/jpeg")
    let photo = Attachment(
      id: draft.id, relativePath: "remote/previously-viewed.jpg", mime: draft.mime,
      byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
      orientation: draft.orientation, durationMs: nil, thumbnailKey: draft.id,
      tinyPreview: try XCTUnwrap(draft.tinyPreview))
    let tiny: PreparedImage = try await withCheckedThrowingContinuation { continuation in
      media.tinyPreview(photo) { continuation.resume(with: $0) }
    }
    let local = LocalFile(url, expectation(description: "saved photo requested after eviction"))
    media.remoteThumbnailProvider = local
    defer { local.release.signal(); tiny.close(); slot.close(); media.close() }
    slot.bind(photo, frame: CGRect(x: 0, y: 0, width: 190, height: 180), kind: .photo)
    slot.seed(try XCTUnwrap(tiny.retained()))
    await fulfillment(of: [local.requested], timeout: 2)
    let first = slot.preview()
    XCTAssertNil(first, "A local decode must not flash the inline blur")
    first?.close()
    local.release.signal()
    for _ in 0..<120 where !slot.hasSharpFrame {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(slot.hasSharpFrame)
    XCTAssertNil(slot.loadAction)
    slot.close(); media.close(); try await h.close()
  }

  // Задерживаем проверку местного видео и убеждаемся, что кнопки отмены ещё нет. При
  // действительной передаче кнопка появляется и позволяет остановить запрос.
  func testVideoTransferControlWaitsForActualNetworkProgress() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let slot = MediaImageSlot(store: media)
    let asset = Attachment(
      id: "uncached-video", relativePath: "remote/uncached.mp4", mime: "video/mp4",
      byteSize: 128, rawWidth: 96, rawHeight: 96, orientation: 1, durationMs: 1000,
      thumbnailKey: "uncached-video")
    let entered = expectation(description: "provider checking for saved data")
    let release = DispatchSemaphore(value: 0)
    let cancel = expectation(description: "user cancelled the actual transfer")
    media.remoteFile = { _, _, token in
      entered.fulfill()
      _ = release.wait(timeout: .now() + 3)
      token.onCancel { cancel.fulfill() }
      token.reportProgress(0)
      let deadline = Date().addingTimeInterval(3)
      while !token.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      throw MediaError.cancelled
    }
    slot.bind(asset, frame: CGRect(x: 0, y: 0, width: 150, height: 150), kind: .video)
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertTrue(slot.loading)
    XCTAssertNil(slot.loadAction, "Reading local data must not present itself as a transfer")
    release.signal()
    for _ in 0..<100 where slot.loadAction == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(slot.loadAction?.1, "Отменить загрузку")
    XCTAssertTrue(slot.performLoadAction(at: CGPoint(x: 75, y: 75)))
    await fulfillment(of: [cancel], timeout: 2)
    slot.close()
    media.close()
    try await h.close()
  }

  // Готовим пять разных рисунков и проверяем цвет каждой ячейки. При сдвиге остаётся прежняя
  // запись текста. После ухода альбом освобождает все кадры и их память.
  func testAlbumPaintsEveryNativeImageAndRetiresAllLeasesOutsideViewport() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let colors: [UIColor] = [.red, .green, .blue, .yellow, .magenta]
    var drafts: [AttachmentDraft] = []
    for (index, color) in colors.enumerated() {
      let url = h.root.appendingPathComponent("tile-\(index).jpg"),
        format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let data = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format)
        .jpegData(withCompressionQuality: 1) { context in
          color.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
      try data.write(to: url)
      drafts.append(try await media.stage(sourceURL: url, mime: "image/jpeg"))
    }
    let row = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: drafts)
    ).inserted[0]
    let
      prepared = PreparedText(
        message: row,
        key: TextLayoutKey(messageID: row.id, revision: 1, width: 300, fontSize: 17, scale: 1)),
      root = CALayer(), scene = RetainedChatScene(container: root)
    root.frame = CGRect(x: 0, y: 0, width: 400, height: 900)
    scene.mediaStore = media
    scene.imageViewport = root.bounds
    let
      fragment = SceneFragment(
        prepared: prepared, part: 0,
        frame: CGRect(x: 10, y: 20, width: prepared.width, height: prepared.height)),
      snapshot = SceneSnapshot(ticket: scene.ticket, fragments: [fragment])
    scene.apply(snapshot)
    for _ in 0..<300 where !(0..<5).allSatisfy({ scene.imageReady(row.id, attachmentIndex: $0) }) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for index in 0..<5 {
      XCTAssertTrue(
        scene.imageReady(row.id, attachmentIndex: index), "Every cell needs real decoded pixels")
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let rendered = try XCTUnwrap(
      UIGraphicsImageRenderer(size: root.bounds.size, format: format).image {
        root.render(in: $0.cgContext)
      }.cgImage)
    var bytes = [UInt8](repeating: 0, count: 400 * 900 * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &bytes, width: 400, height: 900, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(rendered, in: root.bounds)
    let expected = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255]]
    for (index, rect) in prepared.mediaItemRects.enumerated() {
      let pixel = (Int(rect.midY + 20) * 400 + Int(rect.midX + 10)) * 4
      for channel in 0..<3 {
        XCTAssertLessThan(
          abs(Int(bytes[pixel + channel]) - expected[index][channel]), 25,
          "Native album must show the corresponding source's pixels")
      }
    }
    let recordings = scene.metrics.recordings
    scene.apply(snapshot)
    XCTAssertEqual(scene.metrics.recordings, recordings)
    scene.imageViewport = CGRect(x: 0, y: 2000, width: 400, height: 900)
    scene.apply(snapshot)
    for index in 0..<5 {
      XCTAssertNil(
        scene.preview(row.id, attachmentIndex: index), "Offscreen cells detach every decoded lease")
    }
    scene.close()
    media.close()
    prepared.close()
    for _ in 0..<100 where media.bytesUsed > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  // Для нескольких ширин и числа файлов проверяем число и границы прямоугольников. Порядок и
  // отсутствие наложений дают открыть нужное вложение касанием.
  func testEveryAlbumAttachmentHasAnOrderedNonOverlappingHitRectangle() {
    for count in 2...10 {
      for width in [160, 260, 340] {
        let assets = (0..<count).map {
          Attachment(
            id: "tile-\($0)", relativePath: "seed/\($0).jpg",
            mime: $0 % 3 == 1 ? "video/mp4" : "image/jpeg", byteSize: 100,
            rawWidth: $0 % 2 == 0 ? 1600 : 900, rawHeight: $0 % 2 == 0 ? 900 : 1600,
            orientation: $0 % 2 == 0 ? 1 : 6, durationMs: nil, thumbnailKey: "")
        }
        let row = Message(
          id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
          savedAtMs: 1, kind: .photo, text: "", caption: "Альбом", replyToID: nil, revision: 1,
          attachments: assets)
        let text = PreparedText(
          message: row,
          key: TextLayoutKey(messageID: 1, revision: 1, width: width, fontSize: 17, scale: 2))
        defer { text.close() }
        let rects = text.mediaItemRects
        XCTAssertEqual(
          rects.count, count, "Every attachment must remain visible and independently tappable")
        for (index, rect) in rects.enumerated() {
          XCTAssertTrue(
            rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.maxX <= text.width
              && rect.maxY < text.height)
          for other in rects.dropFirst(index + 1) {
            XCTAssertFalse(
              rect.intersects(other), "Album geometry cannot paint one attachment over another")
          }
        }
      }
    }
  }
  private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0, cancelled = 0
    var counts: (Int, Int) {
      lock.lock()
      defer { lock.unlock() }
      return (started, cancelled)
    }
    // Увеличиваем счётчик начатых чтений под блокировкой. Источник работает в фоне, а проверки
    // читают число на экране.
    func begin() {
      lock.lock()
      started += 1
      lock.unlock()
    }
    // Записываем число отменённых чтений под той же защитой. Так можно отличить реальную отмену
    // работы от одного исчезновения картинки.
    func cancel() {
      lock.lock()
      cancelled += 1
      lock.unlock()
    }
  }
  // Двигаем готовую строку из области за экраном к видимой границе и обратно. Фото допускается
  // только рядом с экраном, а при уходе прерывается фактическое чтение. Текстовый узел при этом
  // сохраняется.
  func testPreparedOffscreenPhotoDoesNotDecodeUntilItEntersTheFullViewport() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), reads = Reads()
    let source = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let delta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo,
        caption: "Геометрия подготовлена заранее", attachments: [draft]))
    let row = try XCTUnwrap(delta.inserted.first)
    let prepared = PreparedText(
      message: row,
      key: TextLayoutKey(messageID: row.id, revision: 1, width: 260, fontSize: 17, scale: 1))
    let held = DispatchSemaphore(value: 0), file = try media.fileURL(draft.relativePath)
    media.remoteFile = { _, _, token in
      reads.begin()
      token.onCancel {
        reads.cancel()
        held.signal()
      }
      _ = held.wait(timeout: .now() + 5)
      return (file, "image/jpeg")
    }
    let layer = CALayer(), scene = RetainedChatScene(container: layer)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 80, width: 390, height: 400)
    scene.imageViewport = CGRect(x: 0, y: 0, width: 390, height: 480)
    let snapshot = SceneSnapshot(
      ticket: scene.ticket,
      fragments: [
        SceneFragment(
          prepared: prepared, part: 0,
          frame: CGRect(x: 10, y: 1000, width: prepared.width, height: prepared.height))
      ])
    defer {
      held.signal()
      scene.close()
      media.close()
      prepared.close()
    }
    scene.apply(snapshot)
    let node = try XCTUnwrap(layer.sublayers?.compactMap { $0 as? MessageLayer }.first)
    XCTAssertNil(
      node.image, "Preparing offscreen text must not admit an image owner or its tiny decode")
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(
      reads.counts.0, 0, "No normal/network thumbnail work before the image enters the viewport")
    let recordings = scene.metrics.recordings
    let imageRect = try XCTUnwrap(prepared.mediaRect).offsetBy(dx: 10, dy: 1000)
    scene.imageViewport = CGRect(x: 0, y: imageRect.minY - 480 - 21, width: 390, height: 480)
    scene.apply(snapshot)
    XCTAssertNil(
      node.image, "A poster21pt outside the screen must stay outside the20pt admission runway")
    scene.imageViewport = CGRect(x: 0, y: imageRect.minY - 480 - 19, width: 390, height: 480)
    scene.apply(snapshot)
    for _ in 0..<300 where !scene.imageReady(row.id) || reads.counts.0 == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(
      scene.imageReady(row.id), "The20pt runway prepares real light pixels before the edge enters")
    let edgeOwner = node.image
    scene.imageViewport = CGRect(x: 0, y: 1000, width: 390, height: 480)
    scene.viewport = CGRect(x: 0, y: 1100, width: 390, height: 300)
    scene.apply(snapshot)
    for _ in 0..<300 where !scene.imageReady(row.id) || reads.counts.0 == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(
      scene.imageReady(row.id),
      "Light pixels remain painted in the full viewport, including behind the glass")
    XCTAssertTrue(
      node.image === edgeOwner, "Crossing the glass boundary reuses the existing native image owner"
    )
    XCTAssertEqual(reads.counts.0, 1)
    XCTAssertEqual(
      scene.nodeIdentity(for: FragmentID(messageID: row.id, part: 0)), ObjectIdentifier(node))
    XCTAssertEqual(
      scene.metrics.recordings, recordings,
      "Image visibility never records the prepared static message again")
    scene.imageViewport = CGRect(x: 0, y: 0, width: 390, height: 480)
    scene.apply(snapshot)
    XCTAssertNil(
      node.image, "Leaving retires only the native image owner, preserving the message node")
    for _ in 0..<100 where reads.counts.1 == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(reads.counts.1, 1, "Leaving the viewport must cancel the actual held I/O")
    scene.close()
    media.close()
    for _ in 0..<100 where media.bytesUsed > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(media.bytesUsed, 0)
    prepared.close()
    try await h.close()
  }
  // Показываем фото, открываем поле ввода и накладываем поверх просмотр. Слой чёткого снимка
  // должен оставаться на прежнем месте за клавиатурой и прозрачной подложкой.
  func testOpeningLocalKeyboardKeepsTheVisiblePhotoAttached() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store),
      state = ConversationState(repository: h.repo), admission = MediaAdmission(),
      playback = MediaCoordinator(admission: admission, media: media)
    let
      file = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
        .appendingPathComponent("media/photo-000.jpg"),
      draft = try await media.stage(sourceURL: file, mime: "image/jpeg")
    let delta = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: [draft]))
    let id = try XCTUnwrap(delta.inserted.first?.id)
    try await state.open(chatID: 2)
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    let chrome = ConversationChrome(
      chatID: 2, state: state, media: media, admission: admission, playback: playback, onBack: {})
    root.view = chrome
    window.rootViewController = root
    window.makeKeyAndVisible()
    chrome.frame = window.bounds
    defer {
      root.presentedViewController?.dismiss(animated: false)
      chrome.persistAnchorAndClose()
      playback.close()
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await chrome.openHistory(repository: h.repo, anchor: nil)
    // Обходим вложенные слои, пока не найдём слои сообщений. Проверке нужен именно владелец
    // кадра, даже если он находится внутри другой подложки.
    func nodes(_ layer: CALayer) -> [MessageLayer] {
      (layer.sublayers ?? []).flatMap { ($0 as? MessageLayer).map { [$0] } ?? nodes($0) }
    }
    let deadline = Date().addingTimeInterval(5)
    var slot: MediaImageSlot?
    while Date() < deadline {
      slot = nodes(chrome.layer).first { $0.fragment?.id.messageID == id }?.image
      if slot?.ready == true { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let photo = try XCTUnwrap(slot)
    XCTAssertTrue(photo.ready)
    let input = try XCTUnwrap(
      chrome.subviews.first { $0.accessibilityIdentifier == "composer.input" } as? UITextView)
    XCTAssertTrue(input.becomeFirstResponder())
    chrome.layoutIfNeeded()
    XCTAssertTrue(input.isFirstResponder)
    XCTAssertTrue(
      photo.ready, "A keyboard leaves the chat visible, so it must retain its static photo")
    XCTAssertNotNil(
      photo.layer.superlayer, "Opening a media keyboard must not detach the underlying photo")
    input.resignFirstResponder()
    let plus = try XCTUnwrap(
      chrome.subviews.compactMap { $0 as? UIControl }.first {
        $0.accessibilityIdentifier == "composer.plus"
      })
    plus.sendActions(for: .touchUpInside)
    chrome.layoutIfNeeded()
    XCTAssertTrue(
      photo.ready,
      "The gallery sheet leaves part of the chat visible and must retain its static photo")
    XCTAssertNotNil(photo.layer.superlayer, "A photo behind the gallery glass must remain attached")
    chrome.stopCapture()
    chrome.persistAnchorAndClose()
    playback.close()
    media.close()
    await state.close()
    try await h.close()
  }
  // Подготавливаем фото с подписью и проверяем, что текст находится ниже вложения. После сдвига
  // готовый рисунок остаётся прежним, а непрозрачный просмотр убирает кадры под ним.
  func testVisiblePhotoUsesNativeMailboxAndScrollingDoesNotRecordTextAgain() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let source = Bundle(for: RepositoryHarness.self).url(
      forResource: "fixtures", withExtension: nil)!.appendingPathComponent("media/photo-000.jpg")
    let d = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let delta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo,
        caption: "Подпись", attachments: [d]))
    let row = delta.inserted[0]
    let text = PreparedText(
      message: row,
      key: TextLayoutKey(messageID: row.id, revision: 1, width: 260, fontSize: 17, scale: 1))
    let rect = try XCTUnwrap(text.mediaRect)
    XCTAssertGreaterThan(rect.height, 100)
    XCTAssertGreaterThan(
      text.accessibleLines(from: 0, to: 1000, limit: 128)[0].frame.minY, rect.maxY)
    let container = CALayer()
    let scene = RetainedChatScene(container: container)
    scene.mediaStore = media
    let ready = expectation(description: "real decoded frame published")
    ready.assertForOverFulfill = false
    scene.onImageReady = { if scene.imageReady(row.id) { ready.fulfill() } }
    // Формируем снимок сцены с одной строкой в переданной вертикальной точке. Сдвигая его, можно
    // наблюдать тот же ресурс без новой разметки.
    func snapshot(_ y: CGFloat) -> SceneSnapshot {
      SceneSnapshot(
        ticket: scene.ticket,
        fragments: [
          SceneFragment(
            prepared: text, part: 0,
            frame: CGRect(x: 0, y: y, width: text.width, height: text.height))
        ])
    }
    scene.apply(snapshot(0))
    await fulfillment(of: [ready], timeout: 5)
    XCTAssertTrue(scene.imageReady(row.id))
    XCTAssertFalse(container.sublayers?.isEmpty ?? true)
    XCTAssertGreaterThan(media.bytesUsed, 0)
    let rasterReady = Date().addingTimeInterval(3)
    while scene.metrics.recordings < 1, Date() < rasterReady {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let recordings = scene.metrics.recordings
    XCTAssertEqual(recordings, 1)
    for n in 0..<1000 { scene.apply(snapshot(CGFloat(n % 30))) }
    XCTAssertEqual(scene.metrics.recordings, recordings)
    scene.mediaVisible = false
    scene.apply(snapshot(0))
    let keptOccludedImage = scene.imageReady(row.id)
    scene.mediaVisible = true
    scene.apply(snapshot(0))
    for _ in 0..<300 where !scene.imageReady(row.id) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(
      scene.imageReady(row.id), "Returning from a viewer must restore the timeline image")
    XCTAssertEqual(
      scene.metrics.recordings, recordings,
      "Restoring image owners must not redraw static message content")
    scene.close()
    media.close()
    XCTAssertEqual(container.sublayers?.count ?? 0, 0)
    XCTAssertFalse(keptOccludedImage, "An opaque viewer must retire the image owners behind it")
    for _ in 0..<100 where media.bytesUsed > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(
      media.bytesUsed, 0, "Cancelled quality upgrade must release its actual pixel lease")
    text.close()
    try await h.close()
  }
}
