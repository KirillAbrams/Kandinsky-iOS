// Проверяем полноэкранный просмотр фото и видео на айфоне. Сценарии сверяют кадры при
// перелистывании, отмену оригинала, повтор источника и возврат одного общего проигрывателя в
// историю.

import XCTest
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import Kandinsky

@MainActor final class MediaGalleryPresentationTests: XCTestCase {
  private final class Downloads: @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String] = []
    private var cancelled = 0
    var counts: (Int, Int) {
      lock.lock()
      defer { lock.unlock() }
      return (originals.count, cancelled)
    }
    // Увеличиваем число чтений оригинала под блокировкой. Так сравниваем запросы выбранной
    // страницы с работой соседей.
    func fetch(_ path: String = "") {
      lock.lock()
      originals.append(path)
      lock.unlock()
    }
    func reads(of path: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return originals.filter { $0 == path }.count
    }
    // Отмечаем отмену фактической передачи под блокировкой. По этому числу видно, сколько
    // загрузок завершились при уходе.
    func cancel() {
      lock.lock()
      cancelled += 1
      lock.unlock()
    }
  }
  // Ждём заданное видимое состояние с ограниченным сроком. Если оно не наступило, выводим
  // сообщение об ожидаемом этапе.
  private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(condition(), message)
  }
  // Рекурсивно собираем дочерние виды окна. Так находим кнопку или подпись, даже когда её вложили
  // в дополнительную панель.
  private func descendants(_ view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }

  func testProgressControlStopsAnimatingWhenHiddenAndShowsTheRetryAction() throws {
    let control = MediaProgressControl(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    let layers = try XCTUnwrap(control.layer.sublayers?.compactMap { $0 as? CAShapeLayer })
    XCTAssertEqual(layers.count, 2)
    let ring = try XCTUnwrap(layers.first)
    let symbol = try XCTUnwrap(layers.last)
    XCTAssertTrue(control.isHidden)
    control.foregroundColor = .systemBlue
    XCTAssertEqual(try XCTUnwrap(ring.strokeColor), UIColor.systemBlue.cgColor)
    XCTAssertEqual(try XCTUnwrap(symbol.strokeColor), UIColor.systemBlue.cgColor)
    control.update(progress: nil, visible: true)
    control.layoutIfNeeded()
    let cancel = try XCTUnwrap(symbol.path).boundingBox
    XCTAssertFalse(control.isHidden)
    XCTAssertEqual(control.accessibilityIdentifier, "media.cancel")
    XCTAssertEqual(control.accessibilityValue, "Загрузка")
    XCTAssertNotNil(ring.animation(forKey: "loading"))

    control.update(progress: 0.43, visible: true)
    XCTAssertEqual(ring.strokeEnd, 0.43, accuracy: 0.001)
    XCTAssertEqual(control.accessibilityValue, "43%")
    XCTAssertNil(ring.animation(forKey: "loading"))
    control.update(progress: nil, visible: true, retry: true)
    control.layoutIfNeeded()
    XCTAssertEqual(control.accessibilityIdentifier, "media.retry")
    XCTAssertEqual(control.accessibilityLabel, "Повторить загрузку")
    XCTAssertNotEqual(try XCTUnwrap(symbol.path).boundingBox, cancel)
    XCTAssertNil(ring.animation(forKey: "loading"))

    control.update(progress: nil, visible: false)
    XCTAssertTrue(control.isHidden)
    XCTAssertNil(ring.animation(forKey: "loading"))
  }

  func testPhotoWithoutAHistoryUsesOneStandaloneViewerAndReturnsToChat() async throws {
    let h = try await RepositoryHarness.open()
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    let draft = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/photo-000.jpg"), mime: "image/jpeg")
    let delta = try await h.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Отдельное фото",
      attachments: [draft]))
    let row = try XCTUnwrap(delta.inserted.first)

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let parent = UIViewController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = parent
    window.makeKeyAndVisible()
    let host = ChatScrollHost()
    host.frame = parent.view.bounds
    parent.view.addSubview(host)
    host.configureMedia(media)
    host.configurePlayback(playback, media: media)
    host.setMediaVisible(true)
    defer {
      host.close()
      playback.close()
      admission.close()
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }

    XCTAssertNil(host.repository)
    let frame = CGRect(x: 8, y: 20, width: 260, height: 160)
    host.activateMedia(row, frame: frame)
    let viewer = try XCTUnwrap(host.photoViewer)
    XCTAssertNil(host.mediaGallery)
    XCTAssertFalse(host.scene.mediaVisible)
    host.activateMedia(row, frame: frame)
    XCTAssertTrue(host.photoViewer === viewer)
    try await waitFor("Отдельное окно показывает подготовленное фото") {
      let preview = viewer.retainedPreview()
      defer { preview?.close() }
      return preview?.image != nil && parent.presentedViewController === viewer
    }
    let caption = try XCTUnwrap(descendants(viewer.view).compactMap { $0 as? UITextView }
      .first { $0.accessibilityIdentifier == "viewer.caption" })
    XCTAssertEqual(caption.text, "Отдельное фото")
    let close = try XCTUnwrap(descendants(viewer.view).compactMap { $0 as? UIButton }
      .first { $0.accessibilityIdentifier == "photo.close" })
    close.sendActions(for: .touchUpInside)
    try await waitFor("После закрытия просмотр освобождает ленту") {
      host.photoViewer == nil && parent.presentedViewController == nil && host.scene.mediaVisible
    }
    try await h.close()
  }

  func testRemovingTheLastVisiblePhotoClosesTheGalleryExactlyOnce() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    defer {
      playback.close()
      media.close()
      admission.close()
    }
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let draft = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/photo-000.jpg"), mime: "image/jpeg")
    let inserted = try await h.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Один снимок",
      attachments: [draft]))
    let message = try XCTUnwrap(inserted.inserted.first)
    let gallery = MediaGalleryController(
      seed: message, repository: h.repo, media: media, playback: playback,
      surface: InlinePlayerSurface(coordinator: playback), preview: nil)
    var returned = 0
    gallery.onReturn = { returned += 1 }
    gallery.loadViewIfNeeded()
    gallery.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    gallery.viewDidLayoutSubviews()
    let caption = try XCTUnwrap(
      gallery.view.subviews.compactMap { $0 as? UITextView }
        .first { $0.accessibilityIdentifier == "viewer.caption" })
    XCTAssertEqual(caption.text, "Один снимок")
    XCTAssertFalse(caption.isHidden)
    let pager = try XCTUnwrap(
      descendants(gallery.view).compactMap { $0 as? UIScrollView }.first {
        $0.accessibilityIdentifier == "viewer.pages"
      })
    let center = pager.bounds.width
    XCTAssertGreaterThan(center, 0)
    for offset in [center / 2, center * 1.5] {
      pager.contentOffset.x = offset
      gallery.scrollViewDidScroll(pager)
      gallery.scrollViewDidEndScrollingAnimation(pager)
      XCTAssertEqual(pager.contentOffset.x, center, accuracy: 0.5)
      XCTAssertEqual(caption.text, "Один снимок")
    }
    let actualDeletion = try await h.repo.delete(messageID: message.id)
    gallery.apply(actualDeletion)
    XCTAssertEqual(returned, 1)
    gallery.apply(actualDeletion)
    gallery.close(animated: false)
    XCTAssertEqual(returned, 1)
    XCTAssertNil(playback.currentMessageID)
    XCTAssertTrue(descendants(gallery.view).allSatisfy {
      $0.accessibilityIdentifier?.hasPrefix("viewer.page.") != true
    })
    let remaining = try await h.repo.history(PageRequest(chatID: 2)).rows
    XCTAssertTrue(remaining.isEmpty)
    try await h.close()
  }

  func testNeighbourPageWaitsForTheActiveAlbumSwipeToSettle() async throws {
    let harness = try await RepositoryHarness.open()
    let media = MediaStore(store: harness.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    defer {
      playback.close()
      media.close()
      admission.close()
    }
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let source = fixtures.appendingPathComponent("media/photo-000.jpg")
    let first = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let second = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let third = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let earlier = try await media.stage(sourceURL: source, mime: "image/jpeg")
    let preceding = try await harness.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo,
      caption: "Предыдущий снимок", attachments: [earlier]))
    let album = try await harness.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo,
      caption: "Два снимка", attachments: [first, second]))
    let following = try await harness.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .photo,
      caption: "Следующий снимок", attachments: [third]))
    let initial = try XCTUnwrap(album.inserted.first)
    let neighbour = try XCTUnwrap(following.inserted.first)
    let previous = try XCTUnwrap(preceding.inserted.first)
    for startAnotherSwipe in [false, true] {
      let gallery = MediaGalleryController(
        seed: initial, repository: harness.repo, media: media, playback: playback,
        surface: InlinePlayerSurface(coordinator: playback), preview: nil)
      gallery.loadViewIfNeeded()
      defer { gallery.close(animated: false) }
      gallery.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      gallery.viewDidLayoutSubviews()
      let pager = try XCTUnwrap(gallery.view.subviews.compactMap { $0 as? UIScrollView }.first)
      let center = pager.bounds.width
      XCTAssertGreaterThan(center, 0)
      let swipe = center * 1.75
      pager.contentOffset.x = swipe
      func hasPage(_ id: MessageID, index: Int) -> Bool {
        gallery.children.contains { $0.view.accessibilityIdentifier == "viewer.page.\(id)/\(index)" }
      }
      let movedBeforeRelease = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        abs(pager.contentOffset.x - swipe) > 0.5 || hasPage(previous.id, index: 0)
      }, object: nil)
      movedBeforeRelease.isInverted = true
      await fulfillment(of: [movedBeforeRelease], timeout: 0.35)
      XCTAssertEqual(pager.contentOffset.x, swipe, accuracy: 0.5)
      XCTAssertTrue(hasPage(initial.id, index: 1))
      XCTAssertFalse(hasPage(neighbour.id, index: 0))
      if startAnotherSwipe {
        gallery.scrollViewWillBeginDragging(pager)
        XCTAssertEqual(pager.contentOffset.x, swipe - center, accuracy: 0.5)
        XCTAssertTrue(hasPage(neighbour.id, index: 0))
      }
      gallery.scrollViewDidEndDragging(pager, willDecelerate: false)
      try await waitFor("После свайпа следующий снимок доступен рядом") {
        hasPage(neighbour.id, index: 0)
      }
      XCTAssertEqual(pager.contentOffset.x, center, accuracy: 0.5)
      pager.contentOffset.x = 2 * center
      gallery.scrollViewDidEndDecelerating(pager)
      let caption = gallery.view.subviews.compactMap { $0 as? UITextView }
        .first { $0.accessibilityIdentifier == "viewer.caption" }
      XCTAssertEqual(caption?.text, "Следующий снимок")
    }
    try await harness.close()
  }

  func testGalleryRetriesItsNeighboursAfterAReadErrorWithoutChangingTheCurrentPhoto() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    defer { playback.close(); admission.close(); media.close() }
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let source = fixtures.appendingPathComponent("real-media/backend-824d66cce0d64409ad4888a13792c7d4.jpg")

    func savePhoto(_ caption: String) async throws -> Message {
      let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
      let sent = try await h.repo.send(SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo,
        caption: caption, attachments: [draft]))
      return try XCTUnwrap(sent.inserted.first)
    }

    let original = try await savePhoto("Открытый снимок")
    let following = try await savePhoto("Снимок справа")
    try await h.store.perform { db in
      try db.execute("UPDATE messages SET direction=? WHERE id=?", [
        .text("invalid-direction"), .integer(following.id),
      ])
    }

    let gallery = MediaGalleryController(
      seed: original, repository: h.repo, media: media, playback: playback,
      surface: InlinePlayerSurface(coordinator: playback), preview: nil)
    defer { gallery.close(animated: false) }
    gallery.loadViewIfNeeded()
    gallery.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    gallery.viewDidLayoutSubviews()
    let pager = try XCTUnwrap(gallery.view.subviews.compactMap { $0 as? UIScrollView }.first)
    let caption = try XCTUnwrap(gallery.view.subviews.compactMap { $0 as? UITextView }.first {
      $0.accessibilityIdentifier == "viewer.caption"
    })
    let unexpectedPage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      gallery.children.count != 1 || caption.text != original.caption
    }, object: nil)
    unexpectedPage.isInverted = true
    await fulfillment(of: [unexpectedPage], timeout: 0.3)

    try await h.store.perform { db in
      try db.execute("UPDATE messages SET direction=? WHERE id=?", [
        .text(following.direction.rawValue), .integer(following.id),
      ])
    }
    gallery.scrollViewDidEndScrollingAnimation(pager)
    try await waitFor("После повтора появился соседний снимок") {
      gallery.children.contains { $0.view.accessibilityIdentifier == "viewer.page.\(following.id)/0" }
    }
    XCTAssertEqual(caption.text, original.caption)
    pager.contentOffset.x = pager.bounds.width * 2
    gallery.scrollViewDidEndDecelerating(pager)
    XCTAssertEqual(caption.text, following.caption)
    gallery.close(animated: false)
    try await h.close()
  }

  func testOpeningAStaleGallerySelectionReturnsWithoutKeepingAnEmptyPage() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    defer {
      playback.close()
      media.close()
      admission.close()
    }
    let sent = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, text: "Медиа уже нет"))
    let empty = try XCTUnwrap(sent.inserted.first)
    let surface = InlinePlayerSurface(coordinator: playback)
    let gallery = MediaGalleryController(
      seed: empty, repository: h.repo, media: media, playback: playback, surface: surface,
      preview: nil)
    var returns = 0
    gallery.onReturn = { returns += 1 }
    gallery.loadViewIfNeeded()
    gallery.close(animated: false)
    XCTAssertEqual(returns, 1)
    XCTAssertTrue(gallery.children.isEmpty)
    XCTAssertNil(surface.superview)
    XCTAssertNil(playback.currentMessageID)
    try await h.close()
  }

  // Убираем оригинал и заново создаём уже просмотренную страницу. Она должна найти чёткую копию
  // без сети. Очистка удаляет и эту подготовленную копию.
  func testARecreatedGalleryPageFindsItsSharpCopyAfterOriginalEviction() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let artwork = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let draft = try await media.stage(sourceURL: artwork, mime: "image/jpeg")
    let photo = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: nil, thumbnailKey: draft.id, tinyPreview: draft.tinyPreview)
    let first = PhotoViewerController(attachment: photo, media: media, embedded: true)
    first.loadViewIfNeeded()
    first.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    first.viewDidLayoutSubviews()
    try await waitFor("The first gallery page must have shown a sharp image") {
      media.wasShownInGallery(photo)
    }
    first.closePage()
    media.releaseIdleImages()
    try FileManager.default.removeItem(at: media.fileURL(photo.relativePath))
    media.remoteFile = { _, _, _ in
      XCTFail("Returning to a viewed gallery photo needs no download while its copy exists")
      throw MediaError.unavailable
    }
    let recreated = PhotoViewerController(attachment: photo, media: media, embedded: true)
    recreated.loadViewIfNeeded()
    recreated.view.frame = first.view.frame
    recreated.viewDidLayoutSubviews()
    try await waitFor("A recreated gallery page must display the saved sharp image") {
      guard let frame = recreated.retainedPreview() else { return false }
      defer { frame.close() }
      XCTAssertFalse(frame.isTinyPreview)
      return !frame.isTinyPreview
    }
    recreated.closePage()
    let saved = VideoCoverDiskCache(root: h.store.root)
    XCTAssertNotNil(saved.galleryFile(photo.relativePath))
    try VideoCoverDiskCache.revoke(root: h.store.root, relativePath: photo.relativePath)
    XCTAssertNil(saved.galleryFile(photo.relativePath))
    saved.close()
    media.close()
    try await h.close()
  }

  // Перелистываем большие фото под пределом памяти. На выбранной странице нужен крупный рисунок,
  // а соседние освобождают исходное разрешение до подготовки следующего.
  func testPagingLargeOriginalsReleasesInactiveResolutionBeforeTheNextDecode() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission(),
      player = MediaCoordinator(admission: admission, media: media)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as! [String: Any]
    let name = try XCTUnwrap(
      (manifest["files"] as? [[String: Any]])?.first { $0["mime"] as? String == "image/jpeg" }?[
        "fileName"] as? String)
    let source = h.root.appendingPathComponent("gallery-large-source.jpg")
    do {
      let reader = try XCTUnwrap(
        CGImageSourceCreateWithURL(fixtures.appendingPathComponent("media/" + name) as CFURL, nil))
      let photo = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 2048, height: 2048, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(photo, in: CGRect(x: 0, y: 0, width: 2048, height: 2048))
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
      )
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    var rows: [Message] = []
    for index in 0..<3 {
      let draft = try await media.stage(sourceURL: source, mime: "image/jpeg")
      let delta = try await h.repo.send(
        SendCommand(
          operationID: UUID().uuidString, chatID: 2, kind: .photo,
          caption: "Большое фото \(index+1)", attachments: [draft]))
      rows.append(try XCTUnwrap(delta.inserted.first))
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene),
      previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), root = UIViewController(),
      surface = InlinePlayerSurface(coordinator: player)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    let viewer = MediaGalleryController(
      seed: rows[0], repository: h.repo, media: media, playback: player, surface: surface,
      preview: nil)
    defer {
      viewer.close(animated: false, returnToChat: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    root.present(viewer, animated: false)
    let pager = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIScrollView }.first {
        $0.accessibilityIdentifier == "viewer.pages"
      })
    // Находим выбранную страницу и читаем ширину её рисунка. По ней различаем крупный кадр и
    // лёгкое соседнее изображение.
    func widthOfCurrent() -> Int {
      guard
        let page = viewer.children.compactMap({ $0 as? PhotoViewerController }).first(where: {
          $0.view.frame.minX == pager.bounds.width + 10
        })
      else { return 0 }
      let image = page.retainedPreview()
      defer { image?.close() }
      return image?.image?.width ?? 0
    }
    try await waitFor("The first real original must reach the native layer") {
      widthOfCurrent() == 2048
    }
    for index in 1...2 {
      pager.contentOffset.x = pager.bounds.width * 2
      pager.delegate?.scrollViewDidEndDecelerating?(pager)
      try await waitFor(
        "Selected original \(index+1) must not remain a preview because neighbours retain full-resolution leases"
      ) { widthOfCurrent() == 2048 }
      print(
        """
        KANDINSKY_GALLERY_LARGE selected=\(index+1) width=\(widthOfCurrent()) bytes=\(media.bytesUsed) \
        peak=\(media.peakBytesUsed)
        """
      )
    }
    for index in (0...1).reversed() {
      media.releaseIdleImages()  // Проверяет повторную подготовку уже скачанного оригинала после очистки его пикселей
      pager.contentOffset.x = 0
      pager.delegate?.scrollViewDidEndDecelerating?(pager)
      try await waitFor("Reverse paging restores original \(index+1) after decoded cache eviction")
      { widthOfCurrent() == 2048 }
    }
    for page in viewer.children.compactMap({ $0 as? PhotoViewerController })
    where page.view.frame.minX != pager.bounds.width + 10 {
      let image = try XCTUnwrap(page.retainedPreview())
      defer { image.close() }
      XCTAssertLessThanOrEqual(
        max(image.image?.width ?? 0, image.image?.height ?? 0), 384,
        "Neighbours retain lightweight pixels")
    }
    XCTAssertLessThanOrEqual(media.peakBytesUsed, 48 * 1024 * 1024)
    viewer.close(animated: false, returnToChat: false)
    media.close()
    try await waitFor("All gallery image leases retire on close") { media.bytesUsed == 0 }
    try await h.close()
  }
  // Проверяем автоматическое видео результата без управления перемоткой. Переключаем вложение и
  // закрываем просмотр. В чат не должен вернуться ручной проигрыватель или действие удаления.
  func testStudioPreviewCloseDoesNotHandAnInteractivePlayerBackToChat() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let admission = MediaAdmission(), player = MediaCoordinator(admission: admission, media: media)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let first = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/video-01.mp4"), mime: "video/mp4")
    let second = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/video-00.mp4"), mime: "video/mp4")
    let delta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .video, attachments: [first, second]))
    let row = try XCTUnwrap(delta.inserted.first)
    XCTAssertEqual(row.attachments.count, 2)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene),
      previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), root = UIViewController(),
      surface = InlinePlayerSurface(coordinator: player)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    let viewer = MediaGalleryController(
      seed: row, repository: h.repo, media: media, playback: player, surface: surface, preview: nil,
      attachmentIndex: 1)
    var didReturn = false
    viewer.onDeleteResult = { _, _ in XCTFail("Closing a preview does not delete a result") }
    viewer.onReturn = { didReturn = true }
    defer {
      viewer.close(animated: false, returnToChat: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    root.present(viewer, animated: false)
    try await waitFor("The preview owns playback") {
      player.currentMessageID == row.id && player.activePlayerCount == 1
    }
    let controls = descendants(surface).filter { $0 is UIControl }
    XCTAssertEqual(controls.count, 0)
    XCTAssertFalse(surface.isUserInteractionEnabled)
    try await waitFor("The video starts without a tap") {
      player.isPlaying && player.positionMs > 0 && surface.hasVideoFrame
    }
    XCTAssertFalse(surface.isUserInteractionEnabled)
    XCTAssertEqual(player.currentTarget?.attachment.id, second.id)
    let playbackItem = player.session.player.currentItem
    let refresh = MessageDelta(updated: [row], chat: delta.chat)
    viewer.apply(refresh)
    player.apply(refresh)
    XCTAssertTrue(player.session.player.currentItem === playbackItem)
    XCTAssertTrue(player.isPlaying)
    let close = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIControl }.first {
        $0.accessibilityIdentifier == "player.inline"
      })
    close.sendActions(for: .touchUpInside)
    try await waitFor("The chat is visible and the interactive preview player was released") {
      didReturn && player.currentMessageID == nil && player.activePlayerCount == 0
        && surface.superview == nil
    }
    try await h.close()
  }

  // Показываем исходное видео, меняем размеры и сохраняем тот же проигрыватель. Затем проверяем,
  // что закрытие и улучшение вызывают ровно своё действие.
  func testSourceVideoKeepsItsPlayerAcrossLayoutsAndClosesWithTheChosenAction() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let player = MediaCoordinator(admission: admission, media: media)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let draft = try await media.stageSelection(
      sourceURL: fixtures.appendingPathComponent("media/video-01.mp4"), mime: "video/mp4")
    let video = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey, tinyPreview: draft.tinyPreview)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    let host = ChatScrollHost()
    window.rootViewController = root
    window.makeKeyAndVisible()
    host.frame = root.view.bounds
    root.view.addSubview(host)
    defer {
      root.dismiss(animated: false)
      host.close()
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    // Ищем кнопку предпросмотра по постоянному имени среди дочерних элементов. Точное имя
    // защищает от нажатия похожей соседней кнопки.
    func button(_ identifier: String, in preview: StudioUploadPreview) throws -> UIButton {
      try XCTUnwrap(descendants(preview.view).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == identifier
      }, identifier)
    }

    var enhancements = 0
    var dismissals = 0
    host.previewStudioVideo(video, onClose: { dismissals += 1 })
    XCTAssertEqual(dismissals, 1)
    host.configurePlayback(player, media: media)
    host.previewStudioVideo(video, onEnhance: { enhancements += 1 }, onClose: { dismissals += 1 })
    let preview = try XCTUnwrap(host.studioPreview)
    let surface = try XCTUnwrap(host.playerSurface)
    let expand = try button("studio.upload.expand", in: preview)
    let collapse = try button("studio.upload.collapse", in: preview)
    let enhance = try button("studio.upload.enhance", in: preview)
    let clock = try XCTUnwrap(descendants(preview.view).compactMap { $0 as? UILabel }.first {
      $0.accessibilityIdentifier == "studio.upload.remaining"
    })
    XCTAssertFalse(expand.isEnabled)
    XCTAssertTrue(collapse.isHidden)
    expand.sendActions(for: .touchUpInside)
    XCTAssertTrue(collapse.isHidden)
    host.previewStudioVideo(video, onClose: { dismissals += 1 })
    XCTAssertEqual(dismissals, 2)

    try await waitFor("В предпросмотре появляется декодированный кадр") {
      surface.hasVideoFrame && expand.isEnabled && !preview.isBeingPresented
    }
    let playbackItem = try XCTUnwrap(player.session.player.currentItem)
    let compactFrame = surface.frame
    XCTAssertGreaterThan(compactFrame.width, 0)
    XCTAssertEqual(compactFrame.width, compactFrame.height)
    XCTAssertLessThan(compactFrame.width, preview.view.bounds.width)
    XCTAssertTrue(["00:00", "00:01", "00:02", "00:03"].contains(try XCTUnwrap(clock.text)))
    XCTAssertEqual(player.currentTarget?.attachment, video)

    expand.sendActions(for: .touchUpInside)
    preview.view.layoutIfNeeded()
    XCTAssertEqual(surface.frame, preview.view.bounds)
    XCTAssertEqual(preview.preferredStatusBarStyle, .lightContent)
    XCTAssertTrue(clock.isHidden)
    XCTAssertTrue(enhance.isHidden)
    XCTAssertFalse(collapse.isHidden)
    XCTAssertTrue(player.session.player.currentItem === playbackItem)
    collapse.sendActions(for: .touchUpInside)
    preview.view.layoutIfNeeded()
    XCTAssertEqual(surface.frame, compactFrame)
    expand.sendActions(for: .touchUpInside)
    XCTAssertTrue(preview.accessibilityPerformEscape())
    preview.view.layoutIfNeeded()
    XCTAssertEqual(surface.frame, compactFrame)
    XCTAssertTrue(player.session.player.currentItem === playbackItem)
    enhance.sendActions(for: .touchUpInside)
    try await waitFor("Улучшение начинается после освобождения предпросмотра") {
      enhancements == 1 && player.activePlayerCount == 0 && surface.superview == nil
    }
    XCTAssertEqual(dismissals, 2)
    XCTAssertNil(player.currentTarget)
    XCTAssertNil(host.studioPreview)
    preview.close(animated: false, enhancing: true)
    XCTAssertEqual(enhancements, 1)

    host.previewStudioVideo(video, onClose: { dismissals += 1 })
    let simple = try XCTUnwrap(host.studioPreview)
    try await waitFor("Предпросмотр открыт для обычного закрытия") {
      simple.viewIfLoaded?.window != nil && !simple.isBeingPresented
    }
    XCTAssertFalse(descendants(simple.view).contains {
      $0.accessibilityIdentifier == "studio.upload.enhance"
    })
    try button("studio.upload.dismiss", in: simple).sendActions(for: .touchUpInside)
    try await waitFor("Обычное закрытие освобождает видеовыход и возвращает в чат") {
      dismissals == 3 && player.activePlayerCount == 0 && surface.superview == nil
    }
    XCTAssertEqual(enhancements, 1)
    try await h.close()
  }

  // На первой попытке выдаём ошибку источника и ждём кнопку повтора. На второй даём настоящий
  // файл и проверяем появление его кадра.
  func testFailedGalleryVideoCanBeRetriedAndPresentsARealFrame() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let player = MediaCoordinator(admission: admission, media: media)
    let surface = InlinePlayerSurface(coordinator: player)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let fixture = fixtures.appendingPathComponent("media/video-01.mp4")
    let video = Attachment(
      id: "retry-video", relativePath: "remote/retry-video.mp4", mime: "video/mp4",
      byteSize: Int64(try Data(contentsOf: fixture).count), rawWidth: 256, rawHeight: 256, orientation: 1,
      durationMs: 2000, thumbnailKey: "retry-video")
    let row = Message(
      id: 31, chatID: 2, order: OrderKey(sortKey: 31, messageID: 31), direction: .incoming,
      savedAtMs: 0, kind: .video, text: "", caption: "Ролик", replyToID: nil, revision: 1,
      attachments: [video])
    let downloads = Downloads()
    media.remotePlayback = { attachment, _ in
      XCTAssertEqual(attachment, video)
      downloads.fetch()
      if downloads.counts.0 == 1 { throw MediaError.unavailable }
      return MediaPlaybackSource(file: fixture)
    }

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    let viewer = MediaGalleryController(
      seed: row, repository: h.repo, media: media, playback: player, surface: surface, preview: nil)
    defer {
      viewer.close(animated: false, returnToChat: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    root.present(viewer, animated: false)
    let retry = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "media.retry" && $0.accessibilityLabel == "Повторить загрузку"
      })
    try await waitFor("После ошибки загрузки появляется кнопка повтора") {
      !retry.isHidden && player.lastError != nil
    }
    XCTAssertEqual(downloads.counts.0, 1)
    retry.sendActions(for: .touchUpInside)
    try await waitFor("После повтора виден кадр оригинального видео") {
      surface.hasVideoFrame && player.currentMessageID == row.id && player.lastError == nil
        && retry.isHidden
    }
    XCTAssertEqual(downloads.counts.0, 2)
    try await h.close()
  }

  func testGeneratedVideoRestartsAfterEnteringBackgroundWithoutADuplicatePlayer() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let player = MediaCoordinator(admission: admission, media: media)
    let surface = InlinePlayerSurface(coordinator: player)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let draft = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/video-01.mp4"), mime: "video/mp4")
    let sent = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .video, caption: "Результат",
        attachments: [draft]))
    let row = try XCTUnwrap(sent.inserted.first)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let viewer = MediaGalleryController(
      seed: row, repository: h.repo, media: media, playback: player, surface: surface, preview: nil)
    viewer.onDeleteResult = { _, _ in XCTFail("Переход в фон не удаляет результат") }
    defer {
      viewer.close(animated: false, returnToChat: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }

    root.present(viewer, animated: false)
    try await waitFor("В открытом результате виден настоящий кадр") {
      player.currentMessageID == row.id && surface.hasVideoFrame && player.isPlaying
    }
    let first = try XCTUnwrap(player.session.player.currentItem)
    NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    XCTAssertTrue(player.session.player.currentItem === first)
    NotificationCenter.default.post(
      name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
    try await waitFor("Уход в фон освобождает текущий ролик") {
      player.currentMessageID == nil && player.session.player.currentItem == nil
    }

    NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    try await waitFor("Возврат показывает кадр того же результата") {
      player.currentMessageID == row.id && surface.hasVideoFrame && player.isPlaying
    }
    let resumed = try XCTUnwrap(player.session.player.currentItem)
    XCTAssertFalse(resumed === first)
    NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    XCTAssertTrue(player.session.player.currentItem === resumed)

    root.dismiss(animated: false)
    try await waitFor("Закрытие окна извне освобождает проигрыватель") {
      root.presentedViewController == nil && player.currentMessageID == nil
    }
    NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    XCTAssertNil(player.session.player.currentItem)
    try await h.close()
  }

  // Удерживаем подготовку рисунка автоматического видео. Скрытый элемент загрузки не должен быть
  // доступен для нажатия или озвучивания.
  func testAutoplayPosterDoesNotExposeAnInvisibleDownloadAction() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store, studioOriginals: true)
    let slot = MediaImageSlot(store: media)
    defer {
      slot.close()
      media.close()
    }
    let video = Attachment(
      id: "video", relativePath: "remote/video.mp4", mime: "video/mp4", byteSize: 100,
      rawWidth: 640, rawHeight: 384, orientation: 1, durationMs: 5000, thumbnailKey: "video")
    slot.bind(
      video, frame: CGRect(x: 0, y: 0, width: 260, height: 150), kind: .video, showControls: false)
    XCTAssertTrue(slot.loading)
    XCTAssertNil(slot.loadAction)
    XCTAssertFalse(slot.performLoadAction(at: CGPoint(x: 130, y: 75)))
    try await h.close()
  }

  // Меняем карточку с работы на готовый ответ, задерживая фото. Индикатор остаётся тем же до
  // видимого кадра, а после снимается.
  func testStudioPhotoKeepsTheSameIndicatorUntilPixelsArePresented() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let gate = DispatchSemaphore(value: 0)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let file = fixtures.appendingPathComponent("media/photo-000.jpg")
    media.remoteFile = { _, preview, _ in
      guard !preview, gate.wait(timeout: .now() + 8) == .success else {
        throw MediaError.unavailable
      }
      return (file, "image/jpeg")
    }
    let container = CALayer()
    container.bounds = CGRect(x: 0, y: 0, width: 400, height: 650)
    let scene = RetainedChatScene(container: container)
    scene.mediaStore = media
    let photo = Attachment(
      id: "net-1-result-first", relativePath: "remote/first.jpg", mime: "image/jpeg", byteSize: 100,
      rawWidth: 1024, rawHeight: 1024, orientation: 1, durationMs: nil, thumbnailKey: "first")
    // Формируем две стадии одной ячейки с тем же ключом. Это позволяет проверить сохранение
    // индикатора при смене сведений о файле.
    func snapshot(ready: Bool) -> SceneSnapshot {
      let cells = [
        StudioGeneration.Slot(
          id: "first", status: ready ? .succeeded : .running, blobId: ready ? "first" : nil,
          progress: ready ? 100 : 94),
        StudioGeneration.Slot(id: "second", status: .queued, blobId: nil, progress: nil)
      ]
      let generation = StudioGeneration(
        stage: .running, model: "image", aspect: "1:1", startedAtMs: nil, error: nil, slots: cells)
      let row = Message(
        id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
        savedAtMs: 0,
        kind: ready ? .photo : .text, text: "", caption: "", replyToID: nil,
        revision: ready ? 2 : 1,
        attachments: ready ? [photo] : [], studioGeneration: generation)
      let prepared = PreparedText(
        message: row,
        key: TextLayoutKey(messageID: 1, revision: row.revision, width: 300, fontSize: 17, scale: 2)
      )
      return SceneSnapshot(
        ticket: scene.ticket,
        fragments: [
          SceneFragment(
            prepared: prepared, part: 0,
            frame: CGRect(x: 0, y: 0, width: prepared.width, height: prepared.height))
        ])
    }
    defer {
      gate.signal()
      scene.close()
      media.close()
    }
    scene.apply(snapshot(ready: false))
    let node = try XCTUnwrap(container.sublayers?.compactMap { $0 as? MessageLayer }.first)
    let indicator = try XCTUnwrap(node.progressLayers["first"])
    let ready = snapshot(ready: true)
    scene.apply(ready)
    XCTAssertTrue(node.progressLayers["first"] === indicator)
    XCTAssertEqual(
      indicator.sublayers?.compactMap { ($0 as? CATextLayer)?.string as? String }.last,
      "Загружаем фото")
    XCTAssertFalse(scene.imageReady(1))
    gate.signal()
    try await waitFor("Actual photo pixels are presented") { scene.imageReady(1) }
    scene.apply(ready)
    XCTAssertTrue(node.progressLayers.isEmpty)
    try await h.close()
  }
  // Сначала заполняем два обычных места видео, затем берём ещё два для видимого альбома. Лишнее
  // разрешение сверх предела получает отказ.
  func testVisibleStudioAlbumCanReserveFourVideoPreviews() throws {
    let ordinary = try (0..<2).map { _ in try XCTUnwrap(MediaAdmission.reservePreview(stop: {})) }
    defer { ordinary.forEach { $0.release() } }
    XCTAssertNil(MediaAdmission.reservePreview(stop: {}))

    let album = try (0..<2).map { _ in
      try XCTUnwrap(MediaAdmission.reservePreview(studioAlbum: true, stop: {}))
    }
    defer { album.forEach { $0.release() } }
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 4)
    XCTAssertNil(MediaAdmission.reservePreview(studioAlbum: true, stop: {}))
  }
  // Подаём новое измеренное значение и проверяем цель дуги и анимации перехода и пульса. Один
  // скачок числа не должен заменить плавный показ.
  func testStudioProgressEasesBetweenMeasuredStepsAndPulses() {
    let layer = StudioProgressLayer()
    let frame = CGRect(x: 2, y: 2, width: 140, height: 120)
    layer.bind(frame: frame, progress: 21, scale: 2)
    layer.bind(frame: frame, progress: 65, scale: 2)
    let rings = layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
    XCTAssertEqual(rings.count, 2)
    XCTAssertEqual(rings.last?.strokeEnd, 0.65)
    if !UIAccessibility.isReduceMotionEnabled {
      XCTAssertNotNil(rings.last?.animation(forKey: "progress"))
      XCTAssertNotNil(rings.first?.animation(forKey: "pulse"))
    }
  }

  // Листаем фото, видео и следующее фото, затем возвращаемся к видео. Проверяем выбранные
  // подписи, одну галерею, подготовленный проигрыватель и исходное место истории при закрытии.
  func testGalleryReturnsTheSamePlayingVideoToItsChat() async throws {
    let harness = try await RepositoryHarness.open()
    let media = MediaStore(store: harness.store)
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let video = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/video-00.mp4"), mime: "video/mp4")
    let inserted = try await harness.repo.send(SendCommand(
      operationID: UUID().uuidString, chatID: 2, kind: .video,
      caption: "Ролик из истории", attachments: [video]))
    let row = try XCTUnwrap(inserted.inserted.first)
    let attachment = try XCTUnwrap(row.attachments.first)

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    let host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    host.frame = parent.view.bounds
    parent.view.addSubview(host)
    host.configureMedia(media)
    host.configurePlayback(playback, media: media)
    let owner = try XCTUnwrap(playback.presentationOwner)
    defer {
      host.close()
      parent.dismiss(animated: false)
      playback.close()
      admission.close()
      media.close()
      window.isHidden = true
      previousWindow?.makeKey()
    }

    try await host.open(chatID: 2, repository: harness.repo, anchor: nil)
    try await waitFor("В истории появилась строка с видео") { host.loaded[row.id] != nil }
    playback.play(target: PlaybackTarget(attachment: attachment, messageID: row.id, kind: .video))
    try await waitFor("В ленте виден настоящий кадр") {
      playback.positionMs >= 300 && host.playerSurface?.hasVideoFrame == true
    }
    let surface = try XCTUnwrap(host.playerSurface)
    let item = try XCTUnwrap(playback.session.player.currentItem)
    let position = playback.positionMs

    host.activateMedia(row, frame: .zero)
    let gallery = try XCTUnwrap(host.mediaGallery)
    try await waitFor("Галерея приняла уже открытый ролик") {
      parent.presentedViewController === gallery && playback.presentationOwner != owner
        && gallery.view.window != nil
    }
    XCTAssertTrue(playback.session.player.currentItem === item)
    XCTAssertTrue(descendants(gallery.view).contains { $0 === surface })
    XCTAssertGreaterThanOrEqual(playback.positionMs + 50, position)

    let close = try XCTUnwrap(descendants(gallery.view).compactMap { $0 as? UIButton }
      .first { $0.accessibilityIdentifier == "photo.close" })
    close.sendActions(for: .touchUpInside)
    try await waitFor("Лента снова владеет тем же проигрывателем") {
      host.mediaGallery == nil && playback.presentationOwner == owner
        && parent.presentedViewController == nil
    }
    XCTAssertTrue(playback.session.player.currentItem === item)
    XCTAssertEqual(playback.currentMessageID, row.id)
    let key = VideoPlaybackKey(messageID: row.id, attachment: attachment)
    XCTAssertGreaterThanOrEqual(media.videoPlayback.position(key) * 1000 + 50, Double(position))
    host.close()
    try await harness.close()
  }

  func testPhotoVideoPhotoUsesOnePagedPresentationAndOneNativePlayer() async throws {
    final class CacheMiss: MediaFileProvider {
      // Возвращаем отсутствие готового местного файла для управляемого источника. Галерея не
      // должна случайно использовать чужую картинку.
      func cached(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws
        -> (URL, String)?
      {
        nil
      }
      // Возвращаем недоступность для пробного источника. Настоящие кадры сценарий подаёт своим
      // явным способом.
      func resolve(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws
        -> (URL, String)
      {
        throw MediaError.unavailable
      }
    }
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission(),
      player = MediaCoordinator(admission: admission, media: media)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as! [String: Any]
    let photoName = try XCTUnwrap(
      (manifest["files"] as? [[String: Any]])?.first { $0["mime"] as? String == "image/jpeg" }?[
        "fileName"] as? String)
    let photo = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/" + photoName), mime: "image/jpeg")
    let video = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/video-00.mp4"), mime: "video/mp4")
    let photo2 = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/" + photoName), mime: "image/jpeg")
    let firstDelta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Первое фото",
        attachments: [photo]))
    let secondDelta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .video, caption: "Второе: видео",
        attachments: [video]))
    let thirdDelta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Третье фото",
        attachments: [photo2]))
    let photo3 = try await media.stage(
      sourceURL: fixtures.appendingPathComponent("media/" + photoName), mime: "image/jpeg")
    let fourthDelta = try await h.repo.send(
      SendCommand(
        operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Четвёртое фото",
        attachments: [photo3]))
    let first = try XCTUnwrap(firstDelta.inserted.first),
      second = try XCTUnwrap(secondDelta.inserted.first),
      third = try XCTUnwrap(thirdDelta.inserted.first),
      fourth = try XCTUnwrap(fourthDelta.inserted.first)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene),
      previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), root = UIViewController(), host = ChatScrollHost()
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    host.frame = root.view.bounds
    root.view.addSubview(host)
    host.configureMedia(media)
    host.configurePlayback(player, media: media)
    defer {
      host.close()
      root.dismiss(animated: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await host.open(chatID: 2, repository: h.repo, anchor: nil)
    try await waitFor("Actual history is rendered") { host.metrics.recordings >= 3 }
    let offset = host.contentOffset
    host.onMessageTap?(first, .zero)
    try await waitFor("One real viewer is presented") {
      root.presentedViewController?.view.window != nil
    }
    let viewer = try XCTUnwrap(root.presentedViewController)
    let pager = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIScrollView }.first {
        $0.accessibilityIdentifier == "viewer.pages"
      }, "A media tap must open the paged photo/video viewer")
    try await waitFor("At the first item SQLite supplies only the current and next pages") {
      self.descendants(pager).filter {
        ($0.accessibilityIdentifier ?? "").hasPrefix("viewer.page.")
      }.count == 2
    }
    // Читаем текст только у видимой подписи галереи. Он подтверждает выбранную страницу после
    // перелистывания.
    func caption() -> String? {
      descendants(viewer.view).compactMap { $0 as? UITextView }.first {
        $0.accessibilityIdentifier == "viewer.caption" && !$0.isHidden
      }?.text
    }
    // Переводим галерею на следующую позицию и сообщаем о завершении движения. Используем тот же
    // обработчик, что завершает системный свайп.
    func next() {
      pager.setContentOffset(CGPoint(x: pager.bounds.width * 2, y: 0), animated: false)
      pager.delegate?.scrollViewDidEndDecelerating?(pager)
    }
    // Переводим галерею на предыдущую позицию и завершаем движение. Проверяем, что возврат идёт
    // по прежним страницам.
    func back() {
      pager.setContentOffset(.zero, animated: false)
      pager.delegate?.scrollViewDidEndDecelerating?(pager)
    }
    XCTAssertEqual(caption(), first.caption)
    next()
    try await waitFor("The same presentation selects and prepares the real video") {
      player.currentMessageID == second.id && player.isReady
    }
    XCTAssertEqual(
      descendants(pager).filter { ($0.accessibilityIdentifier ?? "").hasPrefix("viewer.page.") }
        .count, 3)
    XCTAssertTrue(root.presentedViewController === viewer)
    XCTAssertEqual(caption(), second.caption)
    XCTAssertEqual(player.activePlayerCount, 1)
    try await waitFor("The player presents a real frame before paging away") {
      self.descendants(viewer.view).compactMap { $0 as? InlinePlayerSurface }
        .contains { $0.hasVideoFrame }
    }
    try await waitFor("The playback position has visibly advanced") { player.positionMs >= 420 }
    let originalItem = try XCTUnwrap(player.session.player.currentItem)
    let partial = pager.bounds.width * 1.4
    pager.contentOffset.x = partial
    (viewer as? MediaGalleryController)?.apply(
      MessageDelta(updated: [first], chat: firstDelta.chat, reason: .sync))
    XCTAssertEqual(
      pager.contentOffset.x, partial, accuracy: 0.5,
      "A live receipt during paging must not reset the user's gesture")
    next()
    try await waitFor("Horizontal paging reaches the next photo") { caption() == third.caption }
    XCTAssertTrue(root.presentedViewController === viewer)
    XCTAssertNil(viewer.presentedViewController)
    let videoKey = VideoPlaybackKey(messageID: second.id,
      attachment: try XCTUnwrap(second.attachments.first))
    let pausedFrame = try XCTUnwrap(media.videoPlayback.cover(videoKey))
    defer { pausedFrame.close() }
    let adjacent = try XCTUnwrap(viewer.children.compactMap { $0 as? PhotoViewerController }
      .first { $0.view.accessibilityIdentifier == "viewer.page.\(second.id)/0" })
    let visibleFrame = try XCTUnwrap(adjacent.retainedPreview())
    defer { visibleFrame.close() }
    XCTAssertTrue(visibleFrame.image === pausedFrame.image,
      "The neighboring page must display the saved frame before swiping back")
    XCTAssertTrue(player.session.player.currentItem === originalItem)
    XCTAssertFalse(player.isPlaying)
    let parkedPosition = player.positionMs
    try await Task.sleep(for: .milliseconds(175))
    XCTAssertEqual(Double(player.positionMs), Double(parkedPosition), accuracy: 70)
    pager.contentOffset.x = pager.bounds.width * 0.3
    let previousPage = try XCTUnwrap(viewer.children.first { $0.view.frame.minX == 10 })
    let visualX = previousPage.view.frame.minX - pager.contentOffset.x
    pager.delegate?.scrollViewWillBeginDragging?(pager)
    XCTAssertEqual(
      caption(), second.caption,
      "An interrupted reverse swipe commits the nearest visible page before continuing")
    XCTAssertEqual(
      previousPage.view.frame.minX - pager.contentOffset.x, visualX, accuracy: 0.5,
      "Rebasing must preserve the actual image position under the finger")
    XCTAssertTrue(player.session.player.currentItem === originalItem)
    try await waitFor("The same item resumes from its paused position") {
      player.isPlaying && player.positionMs > parkedPosition + 120
    }
    pager.contentOffset.x = pager.bounds.width
    pager.delegate?.scrollViewDidEndDecelerating?(pager)
    next()
    try await waitFor("A subsequent swipe continues normally") { caption() == third.caption }
    next()
    try await waitFor("A second page away frees the player") {
      caption() == fourth.caption && player.currentMessageID == nil && player.activePlayerCount == 0
    }
    let saved = media.videoPlayback.position(videoKey)
    back()
    try await waitFor("A local return prepares and seeks before the video is selected") {
      caption() == third.caption && player.currentMessageID == second.id
        && player.isReady && !player.isPlaying && abs(Double(player.positionMs) / 1000 - saved) < 0.14
    }
    let preparedItem = try XCTUnwrap(player.session.player.currentItem)
    XCTAssertFalse(preparedItem === originalItem)
    back()
    XCTAssertTrue(player.session.player.currentItem === preparedItem)
    try await waitFor("The restored item advances from the saved position") {
      player.isPlaying && Double(player.positionMs) / 1000 > saved + 0.12
    }
    next()
    try await waitFor("The gallery can return to the photo") { caption() == third.caption }
    next()
    try await waitFor("Paging away releases the restored decoder") {
      caption() == fourth.caption && player.currentMessageID == nil
    }
    media.remoteThumbnailProvider = CacheMiss()
    back()
    back()
    try await waitFor("Selecting before a local cache miss falls back to the normal source") {
      caption() == second.caption && player.currentMessageID == second.id
        && player.isPlaying && player.positionMs > 300
    }
    media.remoteThumbnailProvider = nil
    next()
    try await waitFor("The gallery returns to the photo again") { caption() == third.caption }
    let close = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "photo.close"
      })
    close.sendActions(for: .touchUpInside)
    try await waitFor("Viewer returns to the original history") {
      root.presentedViewController == nil
    }
    XCTAssertEqual(host.contentOffset.y, offset.y, accuracy: 1)
    host.close()
    player.close()
    media.close()
    try await h.close()
  }
  // Открываем три страницы и удерживаем оригинал выбранной. Соседи остаются с маленькими кадрами,
  // ручная отмена сохраняется после листания, а закрытие прекращает остальные чтения.
  func testNeighboursKeepPixelsWhileOnlyTheSelectedOriginalLoadsAndCancellationSurvivesPaging()
    async throws
  {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission(),
      player = MediaCoordinator(admission: admission, media: media), downloads = Downloads()
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as! [String: Any]
    let names = try XCTUnwrap(manifest["files"] as? [[String: Any]]).filter {
      $0["mime"] as? String == "image/jpeg"
    }.prefix(4).compactMap { $0["fileName"] as? String }
    XCTAssertEqual(names.count, 4)
    var urls: [String: URL] = [:], rows: [Message] = []
    for (index, name) in names.enumerated() {
      let draft = try await media.stage(
        sourceURL: fixtures.appendingPathComponent("media/" + name), mime: "image/jpeg")
      let delta = try await h.repo.send(
        SendCommand(
          operationID: UUID().uuidString, chatID: 2, kind: .photo, caption: "Фотография \(index+1)",
          attachments: [draft]))
      let path = "remote/gallery-\(index).jpg"
      urls[path] = try media.fileURL(draft.relativePath)
      try await h.store.perform { db in
        try db.execute(
          "UPDATE attachments SET relativePath=? WHERE id=?", [.text(path), .text(draft.id)])
      }
      rows.append(try XCTUnwrap(delta.inserted.first))
    }
    let sources = urls
    media.remoteFile = { attachment, preview, token in
      let url = try XCTUnwrap(sources[attachment.relativePath])
      if preview { return (url, "image/jpeg") }
      downloads.fetch(attachment.relativePath)
      let gate = DispatchSemaphore(value: 0)
      token.onCancel {
        downloads.cancel()
        gate.signal()
      }
      guard gate.wait(timeout: .now() + 8) == .success else { throw MediaError.unavailable }
      // Источник намеренно возвращает данные после отмены, а страница должна отклонить поздний ответ
      return (url, "image/jpeg")
    }
    let all = try await h.repo.history(
      PageRequest(chatID: 2, anchor: nil, direction: .older, limit: 10, visualOnly: true))
    let seed = try XCTUnwrap(all.rows.first { $0.id == rows[1].id })
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene),
      previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), root = UIViewController(),
      surface = InlinePlayerSurface(coordinator: player)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.loadViewIfNeeded()
    let viewer = MediaGalleryController(
      seed: seed, repository: h.repo, media: media, playback: player, surface: surface, preview: nil
    )
    defer {
      viewer.close(animated: false, returnToChat: false)
      player.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    root.present(viewer, animated: false)
    try await waitFor("All three actual page surfaces contain preview pixels") {
      let pages = viewer.children.compactMap { $0 as? PhotoViewerController }
      return pages.count == 3
        && pages.allSatisfy { page in
          let preview = page.retainedPreview()
          defer { preview?.close() }
          return preview?.image != nil
        }
    }
    XCTAssertEqual(
      downloads.counts.0, 1, "Adjacent pages may fetch thumbnails, never their originals")
    let pager = try XCTUnwrap(
      descendants(viewer.view).compactMap { $0 as? UIScrollView }.first {
        $0.accessibilityIdentifier == "viewer.pages"
      })
    let central = try XCTUnwrap(
      viewer.children.compactMap { $0 as? PhotoViewerController }.first {
        $0.view.frame.minX == pager.bounds.width + 10
      })
    let before = try XCTUnwrap(central.retainedPreview())
    let image = try XCTUnwrap(before.image)
    before.close()
    let cancel = try XCTUnwrap(
      descendants(central.view).compactMap { $0 as? UIControl }.first {
        $0.accessibilityIdentifier == "media.cancel" && !$0.isHidden
      })
    cancel.sendActions(for: .touchUpInside)
    try await waitFor("Cancel reaches the actual original I/O") { downloads.counts.1 == 1 }
    let after = try XCTUnwrap(central.retainedPreview())
    XCTAssertTrue(after.image === image, "Cancellation retains the pixels already displayed")
    after.close()
    func page(forward: Bool) {
      pager.contentOffset.x = forward ? pager.bounds.width * 2 : 0
      pager.delegate?.scrollViewDidEndDecelerating?(pager)
    }
    page(forward: true)
    try await waitFor("Only the newly selected original starts") { downloads.counts.0 == 2 }
    page(forward: true)
    try await waitFor("A second swipe removes the cancelled page from the window") {
      downloads.counts.0 == 3 && !viewer.children.contains { $0 === central }
    }
    page(forward: false)
    try await waitFor("Returning past the adjacent page may resume its own original") {
      downloads.counts.0 == 4
    }
    page(forward: false)
    XCTAssertEqual(downloads.counts.0, 4, "Returning to a cancelled page requires explicit retry")
    let rebuilt = try XCTUnwrap(viewer.children.compactMap { $0 as? PhotoViewerController }
      .first { $0.view.accessibilityIdentifier == central.view.accessibilityIdentifier })
    XCTAssertFalse(rebuilt === central)
    let retry = try XCTUnwrap(descendants(rebuilt.view).compactMap { $0 as? UIControl }.first {
      $0.accessibilityIdentifier == "media.retry" && !$0.isHidden
    })
    try await waitFor("Leaving the previous page cancels its request") { downloads.counts.1 == 4 }
    let cancelledPhoto = "remote/gallery-1.jpg"
    let attempted = downloads.reads(of: cancelledPhoto)
    retry.sendActions(for: .touchUpInside)
    try await waitFor("The explicit retry starts the original again") {
      downloads.reads(of: cancelledPhoto) > attempted
    }
    for (forward, target) in [(true, 2), (true, 3), (false, 2), (false, 1)] {
      let path = "remote/gallery-\(target).jpg"
      let earlier = downloads.reads(of: path)
      page(forward: forward)
      try await waitFor("The chosen original starts on page \(target)") {
        downloads.reads(of: path) > earlier
      }
    }
    XCTAssertEqual(viewer.children.count, 3)
    XCTAssertEqual(player.activePlayerCount, 0)
    viewer.close(animated: false, returnToChat: false)
    try await waitFor("Closing retires every actual image lease") { media.bytesUsed == 0 }
    XCTAssertEqual(downloads.counts.1, downloads.counts.0)
    try await h.close()
  }
}
