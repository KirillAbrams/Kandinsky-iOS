// Проверки возврата к уже открытым чатам и медиа на айфоне. Сохранённые кадры должны появляться
// сразу, но уход с экрана и нехватка памяти по-прежнему освобождают ненужное.

import XCTest
import UIKit
@testable import Kandinsky

@MainActor final class WarmNavigationCacheTests: XCTestCase {
  // Вызываем быстрый поиск после очистки рисунка из памяти. Отсутствие результата означает, что
  // чтение с диска нужно назначить отдельно, а экран не ждёт его внутри вызова.
  func testFrameLookupDoesNotReadDiskOnTheUiThread() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = ImageByteBudget()
    let attachment = Attachment(id: "cover", relativePath: "remote/cover.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 64, rawHeight: 64, orientation: 1, durationMs: 3000, thumbnailKey: "cover")
    let key = VideoPlaybackKey(messageID: 81001, attachment: attachment)
    let image = try XCTUnwrap(UIImage(contentsOfFile: source().path))
    let pixels = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image {
      _ in image.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
    }.cgImage)
    let disk = VideoCoverDiskCache(root: root)
    try disk.store(pixels, key: key)
    disk.close()
    let cache = VideoPlaybackCache(budget: budget, root: root)
    let frame = cache.cover(key)
    let returnedFrame = frame != nil
    frame?.close()
    cache.close()
    XCTAssertFalse(returnedFrame, "An empty RAM lookup must schedule restoration separately")
    XCTAssertEqual(budget.bytes, 0)
  }

  // Меняем карточку из двух видео на одно. Проверяем, что слой сообщения остаётся, один ролик
  // закреплён за ним, а прежние связи альбома сняты.
  func testAlbumBecomingSingleKeepsOnlyTheRemainingVideoBinding() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let root = CALayer(), scene = RetainedChatScene(container: root)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    scene.imageViewport = scene.viewport
    let a = Attachment(id: "one", relativePath: "missing/one.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 640, rawHeight: 360, orientation: 1, durationMs: 3000,
      thumbnailKey: "one")
    let b = Attachment(id: "two", relativePath: "missing/two.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 640, rawHeight: 360, orientation: 1, durationMs: 3000,
      thumbnailKey: "two")
    defer { scene.close(); media.close() }
    // Собираем одну редакцию сообщения с переданным набором файлов и применяем её к сцене.
    // Возвращаем слой, чтобы сравнить его до и после удаления ячейки.
    func show(_ attachments: [Attachment], revision: Int) throws -> MessageLayer {
      let row = Message(id: 79001, chatID: 2, order: OrderKey(sortKey: 1, messageID: 79001),
        direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "", replyToID: nil,
        revision: revision, attachments: attachments)
      let prepared = PreparedText(message: row,
        key: TextLayoutKey(messageID: row.id, revision: revision, width: 320, fontSize: 17, scale: 3))
      scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [SceneFragment(prepared: prepared,
        part: 0, frame: CGRect(x: 12, y: 100, width: prepared.width, height: prepared.height))]))
      return try XCTUnwrap(root.sublayers?.compactMap { $0 as? MessageLayer }.first)
    }
    let album = try show([a, b], revision: 1)
    XCTAssertEqual(album.albumVideos.count, 2)
    let single = try show([a], revision: 2)
    XCTAssertTrue(single === album)
    XCTAssertNotNil(single.video)
    XCTAssertTrue(single.albumVideos.isEmpty,
      "Deleting the other cell must remove obsolete album bindings to the same paused owners")
    scene.close(); media.close(); try await h.close()
  }

  // Заполняем память позициями разных сообщений, проверяем предел и размер кадра. После смены
  // номера запоздалый рисунок не должен вернуться, а полная очистка сбрасывает позицию и память.
  func testVideoReturnCacheBoundsIdentityAndLateInvalidation() throws {
    let budget = ImageByteBudget(), cache = VideoPlaybackCache(budget: budget)
    let attachment = Attachment(id: "same", relativePath: "media/same.mp4", mime: "video/mp4",
      byteSize: 100, rawWidth: 1920, rawHeight: 1080, orientation: 1, durationMs: 3000,
      thumbnailKey: "same")
    // Используем один путь ролика с разными номерами сообщений. Так проверка отличает совпадение
    // файла от совпадения конкретного проигрывания.
    func key(_ id: Int64) -> VideoPlaybackKey { VideoPlaybackKey(messageID: id, attachment: attachment) }
    let ticket = cache.generation
    for id in 1...300 {
      cache.rememberPosition(Double(id), key: key(Int64(id)), generation: ticket)
    }
    XCTAssertEqual(cache.position(key(44)), 0)
    XCTAssertEqual(cache.position(key(45)), 45)
    XCTAssertEqual(cache.position(key(300)), 300)
    for id in 1...10 {
      cache.rememberFrame(key: key(Int64(id)), generation: ticket, width: 1920, height: 1080) { w, h in
        XCTAssertEqual(w, 1024)
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()
      }
    }
    XCTAssertNil(cache.frame(key(3)))
    let frame = try XCTUnwrap(cache.frame(key(4)))
    XCTAssertEqual(frame.image?.width, 1024)
    frame.close()
    XCTAssertLessThanOrEqual(budget.bytes, 16 * 1024 * 1024)
    cache.clearFrames()
    XCTAssertEqual(budget.bytes, 0)
    var lateRender = false
    cache.rememberFrame(key: key(3), generation: ticket, width: 32, height: 32) { _, _ in
      lateRender = true; return nil
    }
    cache.rememberPosition(999, key: key(300), generation: ticket)
    XCTAssertFalse(lateRender)
    XCTAssertEqual(cache.position(key(300)), 300)
    cache.close()
    cache.rememberPosition(999, key: key(300), generation: cache.generation)
    XCTAssertEqual(cache.position(key(300)), 0)
    XCTAssertEqual(budget.bytes, 0)
  }

  // Готовим соседей по направлению прокрутки и оставляем место одному сзади. Сверяем точный набор
  // прочитанных файлов, чтобы разворот мог быстро показать ближайший кадр.
  func testDirectionalPrefetchKeepsAnOppositeNeighborReadyForReversal() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store, studioOriginals: true)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let layer = CALayer(), scene = RetainedChatScene(container: layer)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 0, width: 390, height: 500)
    scene.imageViewport = scene.viewport
    scene.imagePreparationViewport = CGRect(x: 0, y: -1500, width: 390, height: 2320)
    let started = expectation(description: "two forward neighbors and one reverse neighbor")
    started.expectedFulfillmentCount = 3
    let release = DispatchSemaphore(value: 0), gate = NSLock(), original = try source()
    var requested = Set<String>()
    media.remoteFile = { attachment, _, token in
      gate.lock(); let publish = requested.insert(attachment.id).inserted; gate.unlock()
      if publish { started.fulfill() }
      return (original, "image/jpeg")
    }
    let positions: [CGFloat] = [-1500, -1150, -800, 550]
    let fragments = positions.enumerated().map { index, y in
      let id = Int64(index + 1)
      let attachment = Attachment(id: "a\(index + 1)", relativePath: "remote/a\(index + 1).jpg",
        mime: draft.mime, byteSize: draft.byteSize, rawWidth: draft.rawWidth,
        rawHeight: draft.rawHeight, orientation: draft.orientation, durationMs: nil,
        thumbnailKey: "a\(index + 1)", tinyPreview: draft.tinyPreview)
      let row = Message(id: id, chatID: 2, order: OrderKey(sortKey: id, messageID: id),
        direction: .incoming, savedAtMs: 0, kind: .photo, text: "", caption: "", replyToID: nil,
        revision: 1, attachments: [attachment])
      let prepared = PreparedText(message: row,
        key: TextLayoutKey(messageID: id, revision: 1, width: 300, fontSize: 17, scale: 3))
      return SceneFragment(prepared: prepared, part: 0,
        frame: CGRect(x: 0, y: y, width: prepared.width, height: prepared.height))
    }
    let aheadRect = try XCTUnwrap(fragments[2].prepared.mediaRect)
    let oppositeRect = try XCTUnwrap(fragments[3].prepared.mediaRect)
    let aheadCenter = fragments[2].frame.minY + aheadRect.midY
    let oppositeCenter = fragments[3].frame.minY + oppositeRect.midY
    XCTAssertLessThan(abs(oppositeCenter - 250), abs(aheadCenter - 250),
      "Fixture must make the opposite neighbor closer in absolute distance")
    XCTAssertGreaterThan(fragments[3].frame.minY + oppositeRect.minY, 520,
      "The opposite row must stay outside the visible20pt overscan")
    defer { release.signal(); scene.close(); media.close() }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: fragments))
    await fulfillment(of: [started], timeout: 2)
    XCTAssertEqual(requested, Set(["a2", "a3", "a4"]),
      "Keep the nearest two ahead and reserve one place for a reversal")
    scene.close(); media.close(); try await h.close()
  }

  // Выводим список из временного хранилища и сверяем порядок видимых строк и отсутствие кнопки
  // повтора. Открытие должно обходиться сохранёнными сведениями.
  func testStudioDrawerReopensFromSavedChatListWithoutNetwork() async throws {
    let h = try await RepositoryHarness.open(), cache = NetworkStore(userID: 1)
    let profile = NetworkProfile(
      userId: 1, deviceId: "fixture", name: "Offline QA", token: "", expiresAtMs: 0)
    let api = NetworkAPI(profile: nil)
    api.close()
    let sync = NetworkSync(profile: profile, store: h.store, local: h.repo, api: api)
    defer { sync.close() }
    let snapshot = Data(
      """
      {"version":1,"userId":1,"cursor":0,"messages":[],"chats":[
       {"id":9,"title":"Pinned","lastSeq":0,"unreadCount":0,"pinned":true},
       {"id":7,"title":"Newer","lastSeq":0,"unreadCount":0,"pinned":false},
       {"id":6,"title":"Older","lastSeq":0,"unreadCount":0,"pinned":false}]}
      """.utf8)
    let archived = Data(
      """
      {"chats":[{"id":10,"title":"Archived","lastSeq":0,"unreadCount":0,"pinned":false,"archived":true}]}
      """.utf8)
    try await h.store.perform { db in
      try NetworkSchema.install(db)
      _ = try cache.bootstrap(db, data: snapshot)
      _ = try cache.mergeChats(db, data: archived)
    }
    for _ in 0..<2 {
      let drawer = StudioHistoryController(
        network: sync, selected: 7, onOpen: { _ in XCTFail("Unexpected navigation") },
        onCompose: {}, onLogout: {}, onEraseAccount: {}, onDeleted: { _ in })
      drawer.loadViewIfNeeded()
      let table = try XCTUnwrap(
        drawer.view.subviews.flatMap(\.subviews).compactMap { $0 as? UITableView }.first)
      let deadline = Date().addingTimeInterval(1)
      while drawer.numberOfSections(in: table) == 0, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let ids = (0..<drawer.numberOfSections(in: table)).flatMap { section in
        (0..<drawer.tableView(table, numberOfRowsInSection: section)).compactMap { row in
          let cell = drawer.tableView(table, cellForRowAt: IndexPath(row: row, section: section))
          return cell.contentView.subviews.compactMap(\.accessibilityIdentifier).first {
            $0.hasPrefix("chat.row.")
          }
        }
      }
      XCTAssertEqual(ids, ["chat.row.9", "chat.row.7", "chat.row.6"])
      XCTAssertNil(
        (table.tableFooterView as? UIButton)?.title(for: .normal).flatMap { $0.isEmpty ? nil : $0 })
    }
    sync.close()
    try await h.close()
  }

  // Возвращаем путь к одному настоящему фото из проверочных материалов. Тот же исходник
  // используется при всех сравнениях рисунка.
  private func source() throws -> URL {
    try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/backend-824d66cce0d64409ad4888a13792c7d4.jpg")
  }
  // Подготавливаем исходное фото через обычное хранилище и переносим его данные во вложение.
  // Размеры и поворот соответствуют тому же файлу.
  private func asset(_ media: MediaStore) async throws -> Attachment {
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    return Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey)
  }
  // Ждём подготовленный рисунок нужного размера через обычный запрос. Проверка потом может
  // сравнить его с показанным кадром.
  private func decode(_ media: MediaStore, _ attachment: Attachment, _ size: Int) async throws
    -> PreparedImage
  {
    try await withCheckedThrowingContinuation { continuation in
      media.thumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: size), ticket: 0) {
        _, result in continuation.resume(with: result)
      }
    }
  }
  // Заранее готовим соседнее фото, затем задерживаем оригинал при входе строки на экран.
  // Маленький кадр остаётся до готовности, а возвращённая строка использует тот же готовый
  // рисунок без кнопки передачи.
  func testHistoryPhotoWarmsOutsideViewportShowsPreviewAndReusesDecodedFrame() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store, studioOriginals: true)
    let original = try source()
    let draft = try await media.stage(sourceURL: original, mime: "image/jpeg")
    let attachment = Attachment(
      id: "ready", relativePath: "remote/ready.jpg", mime: "image/jpeg", byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: nil, thumbnailKey: "ready", tinyPreview: try XCTUnwrap(draft.tinyPreview))
    let row = Message(
      id: 1, chatID: 2, order: OrderKey(sortKey: 1, messageID: 1), direction: .incoming,
      savedAtMs: 0,
      kind: .photo, text: "", caption: "", replyToID: nil, revision: 1, attachments: [attachment])
    let prepared = PreparedText(
      message: row,
      key: TextLayoutKey(messageID: 1, revision: 1, width: 300, fontSize: 17, scale: 3))
    let layer = CALayer(), scene = RetainedChatScene(container: layer)
    scene.mediaStore = media
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 500)
    scene.viewport = viewport
    scene.imageViewport = viewport
    scene.imagePreparationViewport = CGRect(x: 0, y: 0, width: 390, height: 1100)
    let snapshot = SceneSnapshot(
      ticket: scene.ticket,
      fragments: [
        SceneFragment(
          prepared: prepared, part: 0,
          frame: CGRect(x: 0, y: 550, width: prepared.width, height: prepared.height))
      ])
    let release = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
    let cachedFile = try media.fileURL(attachment.relativePath)
    try FileManager.default.createDirectory(
      at: cachedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: original, to: cachedFile)
    media.remoteFile = { _, preview, _ in
      guard !preview else { throw MediaError.unavailable }
      started.signal()
      guard release.wait(timeout: .now() + 6) == .success else { throw MediaError.interrupted }
      return (original, "image/jpeg")
    }
    defer {
      release.signal()
      scene.close()
      media.close()
    }
    // Читаем ширину видимого кадра и сразу отпускаем свою копию. По размеру различаем маленький и
    // готовый файл, не удерживая его в проверке.
    func width() -> Int {
      let frame = scene.preview(1)
      defer { frame?.close() }
      return frame?.image?.width ?? 0
    }
    // Повторяем короткую проверку до срока и сообщаем имя этапа при промахе. Это позволяет
    // дождаться подготовки, которая завершается в фоне.
    func waitFor(_ description: String, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(3)
      while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(condition(), description)
    }
    scene.apply(snapshot)
    try await waitFor("The downloaded photo is decoded before its row is visible") { width() > 64 }
    XCTAssertEqual(started.wait(timeout: .now()), .timedOut)
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: []))
    media.releaseIdleImages()
    try FileManager.default.removeItem(at: cachedFile)
    scene.apply(snapshot)
    try await waitFor("An uncached offscreen row can prepare its tiny preview") {
      (1...64).contains(width())
    }
    var preparing = false
    try await waitFor("The missing original must be requested before its row appears") {
      if !preparing { preparing = started.wait(timeout: .now()) == .success }
      return preparing
    }
    scene.viewport = viewport.offsetBy(dx: 0, dy: 400)
    scene.imageViewport = scene.viewport
    scene.apply(snapshot)
    var requested = preparing
    try await waitFor("The missing original is requested when the row appears") {
      if !requested { requested = started.wait(timeout: .now()) == .success }
      if !requested { scene.apply(snapshot) }
      return requested
    }
    XCTAssertTrue(
      (1...64).contains(width()), "The tiny preview must survive the start of the original request")
    XCTAssertTrue(scene.loadActions().isEmpty)
    let node = try XCTUnwrap(layer.sublayers?.compactMap { $0 as? MessageLayer }.first)
    XCTAssertTrue(
      node.progressLayers.isEmpty, "Completed history does not get a new generation indicator")
    release.signal()
    try await waitFor("The original replaces the tiny preview") { width() > 64 }
    let visibleViewport = try XCTUnwrap(scene.imageViewport)
    let slot = try XCTUnwrap(node.image)
    let mediaY = try XCTUnwrap(prepared.mediaRect?.minY) + 550
    scene.imageViewport = CGRect(x: 0, y: mediaY - viewport.height - 40,
      width: viewport.width, height: viewport.height)
    scene.apply(snapshot)
    XCTAssertTrue(node.image === slot, "A ready photo just outside the viewport keeps its native layer")
    scene.imageViewport = visibleViewport
    scene.apply(snapshot)
    XCTAssertTrue(node.image === slot, "Reversing to a nearby photo reuses the retained layer")
    let expected = scene.preview(1)
    defer { expected?.close() }
    scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: []))
    scene.apply(snapshot)
    let restored = scene.preview(1)
    defer { restored?.close() }
    XCTAssertTrue(expected?.image === restored?.image)
    XCTAssertTrue(scene.loadActions().isEmpty)
    scene.close()
    media.close()
    try await h.close()
  }
  // Готовим фото до входа в чат и ждём первый кадр. Он должен содержать именно сохранённое
  // изображение и живые фрагменты, а кнопка передачи не должна появиться.
  func testOpenHistoryCompletesWithTheActualInitialPhotoFrameNotOnlyMetadata() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let delta = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: [draft]))
    let row = try XCTUnwrap(delta.inserted.first), attachment = try XCTUnwrap(row.attachments.first)
    let warm = try await decode(media, attachment, 1024)
    let expected = warm.image
    warm.close()
    let admission = MediaAdmission(),
      playback = MediaCoordinator(admission: admission, media: media)
    let model = ConversationState(repository: h.repo)
    try await model.open(chatID: 2)
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), controller = UIViewController()
    let chrome = ConversationChrome(
      chatID: 2, state: model, media: media, admission: admission, playback: playback, onBack: {})
    controller.view = chrome
    window.rootViewController = controller
    window.makeKeyAndVisible()
    chrome.layoutIfNeeded()
    defer {
      chrome.persistAnchorAndClose()
      playback.close()
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await chrome.openHistory(repository: h.repo, anchor: nil)
    let host = try XCTUnwrap(
      Mirror(reflecting: chrome).children.first { $0.label == "timeline" }?.value as? ChatScrollHost
    )
    let scene = try XCTUnwrap(
      Mirror(reflecting: host).children.first { $0.label?.contains("scene") == true }?.value
        as? RetainedChatScene)
    print(
      """
      KANDINSKY_NAV_INITIAL geometry=\(host.bounds) offset=\(host.contentOffset)\
       content=\(host.contentSize)\
       viewport=\(String(describing:scene.imageViewport))\
       mediaVisible=\(scene.mediaVisible) bytes=\(media.bytesUsed)
      """
    )
    if let nodes = Mirror(reflecting: scene).children.first(where: { $0.label == "nodes" })?.value
      as? [FragmentID: MessageLayer]
    {
      for (id, node) in nodes {
        print(
          """
          KANDINSKY_NAV_NODE id=\(id) frame=\(node.frame)\
           media=\(String(describing:node.fragment?.prepared.mediaRect))\
           image=\(String(describing:node.image?.ready))\
           loading=\(String(describing:node.image?.loading))
          """
        )
      }
    }
    XCTAssertGreaterThan(
      host.metrics.liveFragments, 0,
      "Initial history completion must mean visible native fragments, not just index metadata")
    XCTAssertTrue(
      scene.imageReady(row.id), "The first revealed frame must contain the warm real photo")
    let shown = scene.preview(row.id)
    XCTAssertTrue(shown?.image === expected)
    shown?.close()
    XCTAssertTrue(scene.loadActions().isEmpty, "Warm navigation must not reveal a new loader")
    await model.close()
    try await h.close()
  }
  // Убираем кадры из памяти и снова открываем сохранённое место. До готовности должны
  // восстановиться реальные фрагменты и местное фото с ограниченным размером, без лишнего
  // проигрывателя.
  func testReopeningAfterMemoryPressureRebuildsTheActualViewportBeforeCompletion() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    let draft = try await media.stage(sourceURL: source(), mime: "image/jpeg")
    let delta = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .photo, attachments: [draft]))
    let id = try XCTUnwrap(delta.inserted.first?.id)
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow },
      window = UIWindow(windowScene: windowScene)
    var current: ConversationChrome?
    defer {
      current?.persistAnchorAndClose()
      playback.close()
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    for pass in 0..<2 {
      if pass == 1 {
        media.trimMemory()
        XCTAssertEqual(media.bytesUsed, 0)
      }
      let model = ConversationState(repository: h.repo)
      try await model.open(chatID: 2)
      let chrome = ConversationChrome(
        chatID: 2, state: model, media: media, admission: admission, playback: playback, onBack: {})
      current = chrome
      let controller = UIViewController()
      controller.view = chrome
      window.rootViewController = controller
      window.makeKeyAndVisible()
      chrome.layoutIfNeeded()
      try await chrome.openHistory(repository: h.repo, anchor: nil)
      let host = try XCTUnwrap(
        Mirror(reflecting: chrome).children.first { $0.label == "timeline" }?.value
          as? ChatScrollHost)
      let scene = try XCTUnwrap(
        Mirror(reflecting: host).children.first { $0.label?.contains("scene") == true }?.value
          as? RetainedChatScene)
      XCTAssertTrue(
        scene.imageReady(id),
        "Disk decode after pressure must finish before the prepared initial viewport completes")
      XCTAssertTrue(
        scene.loadActions().isEmpty, "A local image cannot regain a loading control on reveal")
      XCTAssertGreaterThan(host.metrics.liveFragments, 0)
      if pass == 1 {
        let pixels = scene.preview(id)
        XCTAssertLessThanOrEqual(max(pixels?.image?.width ?? 0, pixels?.image?.height ?? 0), 512)
        pixels?.close()
      }
      media.withNavigationCache { chrome.persistAnchorAndClose() }
      await model.close()
      current = nil
      XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
      XCTAssertLessThanOrEqual(media.bytesUsed, 8 * 1024 * 1024)
    }
    try await h.close()
  }
  // Закрываем ленту, пока первый кадр ещё ждёт подготовки. Ожидающий вызов должен получить отмену
  // и завершиться.
  func testClosingAnInitialViewportResolvesItsPendingWaiter() async throws {
    let host = ChatScrollHost()
    let pending = Task { try await host.prepareInitialFrame() }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline,
      Mirror(reflecting: host).children.first(where: { $0.label == "initialFrame" }).map({
        Mirror(reflecting: $0.value).children.isEmpty
      }) != false
    { await Task.yield() }
    host.close()
    do {
      try await pending.value
      XCTFail("A closed viewport cannot complete presentation successfully")
    } catch { XCTAssertEqual(error as? RepoError, .cancelled) }
  }
  // Возвращаемся к уже готовому снимку и сравниваем сам рисунок при первом показе. После обычной
  // очистки расход должен стать нулевым.
  func testNavigationKeepsExactPixelsForTheFirstBindAndNormalPurgeStillFreesThem() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    let attachment = try await asset(media), decoded = try await decode(media, attachment, 1024)
    let expected = try XCTUnwrap(decoded.image)
    decoded.close()
    let first = MediaImageSlot(store: media)
    first.bind(attachment, frame: CGRect(x: 0, y: 0, width: 240, height: 180), kind: .photo)
    XCTAssertTrue(first.ready)
    XCTAssertFalse(first.loading)
    XCTAssertNil(first.loadAction)
    media.withNavigationCache {
      first.close()
      media.releaseIdleImages()
    }
    XCTAssertGreaterThan(media.bytesUsed, 0)
    XCTAssertLessThanOrEqual(media.bytesUsed, 8 * 1024 * 1024)
    let next = MediaImageSlot(store: media)
    next.bind(attachment, frame: CGRect(x: 0, y: 0, width: 240, height: 180), kind: .photo)
    XCTAssertTrue(next.ready, "A warm image must be ready before the next main-queue turn")
    XCTAssertFalse(next.loading)
    XCTAssertNil(next.loadAction)
    let lease = next.preview()
    XCTAssertTrue(lease?.image === expected)
    lease?.close()
    next.close()
    media.releaseIdleImages()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  // Заполняем хранилище крупными и обычными изображениями. При переходе оригиналы уходят,
  // недавние небольшие кадры укладываются в восемь мебибайт, а полная очистка освобождает их.
  func testNavigationEvictsOriginalsAndKeepsOnlyEightMiBOfRecentNormalPixels() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    var attachments: [Attachment] = []
    for _ in 0..<6 {
      let attachment = try await asset(media)
      attachments.append(attachment)
      let frame = try await decode(media, attachment, 1024)
      frame.close()
    }
    let last = try XCTUnwrap(attachments.last), original = try await decode(media, last, 2048)
    original.close()
    XCTAssertGreaterThan(media.bytesUsed, 8 * 1024 * 1024)
    media.withNavigationCache { media.releaseIdleImages() }
    XCTAssertGreaterThan(media.bytesUsed, 0)
    XCTAssertLessThanOrEqual(media.bytesUsed, 8 * 1024 * 1024)
    XCTAssertNil(
      media.cachedThumbnail(attachment: last, key: ThumbnailKey(maxPixel: 2048)),
      "Full gallery pixels never survive ordinary navigation")
    let recent = media.cachedThumbnail(attachment: last, key: ThumbnailKey(maxPixel: 1024))
    XCTAssertNotNil(recent)
    recent?.close()
    media.releaseIdleImages()
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }
  // Вкладываем переходы, прерываем их ошибкой и проверяем, что обычная очистка снова работает.
  // Оповещение о памяти и закрытие нельзя отменить поздним выходом из перехода.
  func testNestedThrowingNavigationRestoresPurgeAndDoesNotResurrectMemoryWarningOrClosedStore()
    async throws
  {
    enum Probe: Error { case stop }
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    defer { media.close() }
    let attachment = try await asset(media)
    for closeStore in [false, true] {
      let decoded = try await decode(media, attachment, 512)
      decoded.close()
      XCTAssertThrowsError(
        try media.withNavigationCache {
          try media.withNavigationCache {
            if closeStore { media.close() } else { media.trimMemory() }
            throw Probe.stop
          }
        })
      XCTAssertEqual(media.bytesUsed, 0)
      XCTAssertNil(media.cachedThumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: 512)))
      media.releaseIdleImages()
      XCTAssertEqual(media.bytesUsed, 0)
    }
    try await h.close()
  }
}
