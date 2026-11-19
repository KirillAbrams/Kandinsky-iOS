// Проверки времени жизни воспроизведения на айфоне. Они смотрят на реальные кадры, остановку и
// возврат к сохранённой позиции. Отдельно проверяют, что закрытие, смена файла и уход со строки
// освобождают проигрыватель.

import XCTest
import AVFoundation
import UIKit
import CryptoKit
import CoreImage
@testable import Kandinsky

extension MediaCoordinator {
  var activePlayerCount: Int { nativeItemAttached ? 1 : 0 }
  var nativeItemAttached: Bool { session.player.currentItem != nil }
  var platformPlayerIdentity: ObjectIdentifier { ObjectIdentifier(session.player) }
}

@MainActor final class PlaybackLifetimeTests: XCTestCase {
  // Показываем четыре результата в одной карточке и ждём, пока каждый проигрыватель продвинется.
  // После ухода и возврата снова проверяем движение всех четырёх, а при закрытии освобождаем все
  // места.
  func testFourStudioVideosPlayAndReturnTogether() async throws {
    let harness = try await RepositoryHarness.open()
    let media = MediaStore(store: harness.store, studioOriginals: true)
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let scene = RetainedChatScene(container: root.view.layer)
    scene.mediaStore = media
    defer {
      scene.close()
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    let corpus = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let files = [
      "backend-20c898a2957b4f58afa593749fee3cbd.mp4",
      "backend-990da02cd31e46cfb8fd630c293f3489.mp4"
    ]
    var attachments: [Attachment] = []
    for index in 0..<4 {
      let source = corpus.appendingPathComponent("real-media/" + files[index % files.count])
      let draft = try await media.stage(sourceURL: source, mime: "video/mp4")
      attachments.append(Attachment(
        id: "cell-\(index)", relativePath: draft.relativePath, mime: draft.mime,
        byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
        orientation: draft.orientation, durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey))
    }
    let row = Message(
      id: 79010, chatID: 2, order: OrderKey(sortKey: 1, messageID: 79010),
      direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "",
      replyToID: nil, revision: 1, attachments: attachments)
    let prepared = PreparedText(
      message: row, key: TextLayoutKey(messageID: row.id, revision: 1, width: 320, fontSize: 17, scale: 3))
    XCTAssertEqual(prepared.mediaItemRects.count, 4)
    let fragment = SceneFragment(
      prepared: prepared, part: 0,
      frame: CGRect(x: 12, y: 140, width: prepared.width, height: prepared.height))
    let album = SceneSnapshot(ticket: scene.ticket, fragments: [fragment])
    var redrawQueued = false
    scene.onImageReady = { [weak scene] in
      guard !redrawQueued else { return }
      redrawQueued = true
      DispatchQueue.main.async {
        redrawQueued = false
        scene?.apply(album)
      }
    }
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    // Меняем видимую область для той же карточки и применяем её к сцене. Так имитируем уход за
    // экран и возврат без подмены файлов.
    func show(_ area: CGRect) {
      scene.viewport = area
      scene.imageViewport = area
      scene.apply(album)
    }
    // Ждём четыре готовых проигрывателя и сравниваем их время после короткого промежутка. У
    // одного признака готовности мог оставаться неподвижный кадр.
    func waitForPlayers(_ node: MessageLayer) async throws {
      let deadline = Date().addingTimeInterval(6)
      var players: [AVPlayer] = []
      while Date() < deadline {
        players = node.albumVideos.values.compactMap {
          guard $0.isPlaying, let player = $0.layer.player, player.rate > 0 else { return nil }
          return player
        }
        if players.count == 4 { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(players.count, 4)
      let times = players.map { $0.currentTime().seconds }
      try await Task.sleep(for: .milliseconds(180))
      XCTAssertTrue(zip(players, times).allSatisfy { $0.0.currentTime().seconds > $0.1 + 0.03 })
    }
    show(viewport)
    let node = try XCTUnwrap(root.view.layer.sublayers?.compactMap { $0 as? MessageLayer }.first)
    try await waitForPlayers(node)
    show(viewport.offsetBy(dx: 0, dy: 2000))
    XCTAssertEqual(scene.metrics.activeFrameClocks, 0)
    show(viewport)
    try await waitForPlayers(node)
    scene.close()
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    try await harness.close()
  }

  // Сохраняем чёткие кадры на диск и проверяем предел объёма, чужой номер и повреждённые данные.
  // Сброс и закрытие должны отменить поздний рисунок и вернуть всю занятую память.
  func testDurableVideoCoverIsBoundedAndRejectsWrongKeyCorruptionAndRevocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = VideoCoverDiskCache(root: root), budget = ImageByteBudget()
    let corpus = Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)!
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: corpus.appendingPathComponent("manifest.json"))) as! [String: Any]
    let file = (manifest["files"] as! [[String: Any]]).first {
      ($0["mime"] as? String)?.hasPrefix("image/") == true
    }!["fileName"] as! String
    let source = try XCTUnwrap(UIImage(contentsOfFile: corpus.appendingPathComponent("media/" + file).path))
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image {
      _ in source.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
    }.cgImage!
    // Формируем ключ из номера сообщения и пути файла. Можно проверить неверную принадлежность
    // кадра, не меняя само содержимое ролика.
    func keyFor(_ id: Int64, _ path: String) -> VideoPlaybackKey {
      VideoPlaybackKey(messageID: id, attachment: Attachment(id: "original", relativePath: path,
        mime: "video/mp4", byteSize: 100, rawWidth: 64, rawHeight: 64, orientation: 1,
        durationMs: 1000, thumbnailKey: ""))
    }
    let key = keyFor(81, "remote/one.mp4")
    try cache.store(image, key: key)
    let cover = try XCTUnwrap(cache.readFrameForTest(key, budget: budget))
    XCTAssertEqual(cover.image?.width, image.width)
    XCTAssertFalse(cover.isTinyPreview)
    cover.close()
    XCTAssertEqual(budget.bytes, 0)
    XCTAssertNil(cache.readFrameForTest(keyFor(82, key.relativePath), budget: budget))
    let directory = root.appendingPathComponent("media/video-covers")
    let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "frame" })
    let valid = try Data(contentsOf: record)
    var corrupt = valid
    corrupt[corrupt.count - 1] ^= 1
    try corrupt.write(to: record, options: .atomic)
    XCTAssertNil(cache.readFrameForTest(key, budget: budget))
    XCTAssertEqual(budget.bytes, 0)
    try valid.write(to: record, options: .atomic)
    budget.limit = 0
    XCTAssertNil(cache.readFrameForTest(key, budget: budget))
    budget.limit = 48 * 1024 * 1024
    try FileManager.default.removeItem(at: record)
    let outside = root.appendingPathComponent("outside.frame")
    try valid.write(to: outside)
    try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
    XCTAssertNil(cache.readFrameForTest(key, budget: budget))
    try FileManager.default.removeItem(at: record)
    try cache.store(image, key: key)
    try VideoCoverDiskCache.revoke(root: root, relativePath: key.relativePath)
    try cache.store(image, key: key)
    XCTAssertNil(cache.readFrameForTest(key, budget: budget), "A late frame cannot restore a removed result")
    let obsoleteEpoch = cache.epoch()
    for id in 1000...1600 {
      try VideoCoverDiskCache.revoke(root: root, relativePath: "remote/removed-\(id).mp4")
    }
    try cache.store(image, key: key, epoch: obsoleteEpoch)
    XCTAssertNil(cache.readFrameForTest(key, budget: budget), "An older queued write stays revoked after 601 more deletions")
    XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 64,
      "Deletion must not accumulate permanent marker files")
    let orphan = directory.appendingPathComponent("cover-abandoned.pending")
    try Data([1, 2, 3]).write(to: orphan)
    for id in 100...165 {
      try cache.store(image, key: keyFor(Int64(id), "remote/\(id).mp4"))
    }
    let records = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "frame" }
    XCTAssertEqual(records.count, 64)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    let freshRoot = root.appendingPathComponent("not-written-yet")
    let fresh = VideoCoverDiskCache(root: freshRoot)
    try VideoCoverDiskCache.revoke(root: freshRoot, relativePath: key.relativePath)
    try fresh.store(image, key: key)
    XCTAssertNil(fresh.readFrameForTest(key, budget: budget), "Deletion before the first write still revokes it")
    fresh.close()
    let other = VideoCoverDiskCache(root: root.appendingPathComponent("other-profile"))
    try other.store(image, key: key)
    try VideoCoverDiskCache.revoke(root: root, relativePath: key.relativePath)
    let otherFrame = try XCTUnwrap(other.readFrameForTest(key, budget: budget))
    otherFrame.close()
    other.close()
    XCTAssertLessThanOrEqual(try records.reduce(0) {
      try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    }, 128 * 1024 * 1024)
    cache.close()
    XCTAssertNil(cache.readFrameForTest(key, budget: budget))
    XCTAssertEqual(budget.bytes, 0)
    let playback = VideoPlaybackCache(budget: budget, root: root)
    playback.rememberFrame(key: keyFor(800, "remote/closing.mp4"), generation: playback.generation,
      width: image.width, height: image.height) { _, _ in image }
    playback.close()
    XCTAssertEqual(budget.bytes, 0, "Closing releases queued and running cover ownership")
  }

  // Открываем ролик, затем шесть других, чтобы прежний проигрыватель ушёл из короткого запаса.
  // При возврате сравниваем сразу видимый кадр, затем проверяем готовую позицию и продолжение
  // движения.
  func testFeedReturnAfterSixOtherVideosKeepsSharpOwnCoverWithoutDecoderWait() async throws {
    let (h, media, attachment) = try await make()
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let scene = RetainedChatScene(container: root.view.layer)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    scene.imageViewport = scene.viewport
    defer { scene.close(); media.close(); window.isHidden = true; previous?.makeKey() }
    // Ставим отдельное сообщение целиком или частично в область просмотра и получаем его
    // беззвучный проигрыватель. Это позволяет отдельно испытать раннюю подготовку у края экрана.
    func show(_ id: Int64, partiallyVisible: Bool = false) throws -> SilentVideoPreview {
      let row = Message(id: id, chatID: 2, order: OrderKey(sortKey: id, messageID: id),
        direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "",
        replyToID: nil, revision: 1, attachments: [attachment])
      let prepared = PreparedText(message: row,
        key: TextLayoutKey(messageID: id, revision: 1, width: 320, fontSize: 17, scale: 3))
      let rect = try XCTUnwrap(prepared.mediaRect)
      let top = partiallyVisible ? 844 - rect.minY - rect.height * 0.3 : 140
      scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [SceneFragment(
        prepared: prepared, part: 0,
        frame: CGRect(x: 12, y: top, width: prepared.width, height: prepared.height))]))
      let node = root.view.layer.sublayers?.compactMap { $0 as? MessageLayer }.first
      return try XCTUnwrap(node?.video)
    }
    let first = try show(78001)
    var until = Date().addingTimeInterval(5)
    while Date() < until && !first.active { try await Task.sleep(nanoseconds: 20_000_000) }
    let player = try XCTUnwrap(first.layer.player), item = try XCTUnwrap(player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    until = Date().addingTimeInterval(4)
    while Date() < until && player.currentTime().seconds < 0.7 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    player.pause()
    let paused = player.currentTime().seconds
    print("KANDINSKY_VIDEO_CLOCK pause=\(paused) cache=\(media.videoPlayback.position(VideoPlaybackKey(messageID: 78001, attachment: attachment))) rate=\(player.rate)")
    XCTAssertGreaterThan(paused, 0.65)
    let buffer = try XCTUnwrap(output.copyPixelBuffer(
      forItemTime: player.currentTime(), itemTimeForDisplay: nil), "Keep a real decoded frame for an independent pixel reference")
    let reference = CIImage(cvPixelBuffer: buffer)
    let expected = try XCTUnwrap(CIContext().createCGImage(reference, from: reference.extent))
    item.remove(output)
    first.setVisible(false)
    scene.advanceGeneration()
    let savedKey = VideoPlaybackKey(messageID: 78001, attachment: attachment)
    until = Date().addingTimeInterval(1)
    while Date() < until {
      if let ready = media.videoPlayback.frame(savedKey) {
        ready.close()
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let firstCover = try XCTUnwrap(media.videoPlayback.frame(savedKey), "Paused cover is prepared before exercising eviction")
    firstCover.close()
    for id in 78002...78008 {
      media.videoPlayback.rememberFrame(
        key: VideoPlaybackKey(messageID: Int64(id), attachment: attachment),
        generation: media.videoPlayback.generation, width: 256, height: 256
      ) { width, height in
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(expected, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
      }
    }
    for id in 78002...78008 {
      let neighbor = try XCTUnwrap(media.videoPlayback.frame(
        VideoPlaybackKey(messageID: Int64(id), attachment: attachment)))
      neighbor.close()
    }
    let retained = try XCTUnwrap(media.videoPlayback.frame(savedKey),
      "Recent small covers must survive within the existing byte budget")
    retained.close()
    // Запись кадра завершается до возврата. Новый проигрыватель ещё не успевает показать кадр.
    try await Task.sleep(nanoseconds: 200_000_000)
    let start = ProcessInfo.processInfo.systemUptime
    let preparedOwner = try show(78001, partiallyVisible: true)
    let handoff = try XCTUnwrap(scene.preview(78001))
    print("KANDINSKY_VIDEO_DURABLE_BIND_MS=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
    defer { handoff.close() }
    let frozen = try XCTUnwrap(handoff.image)
    // Приводим ожидаемый и увиденный кадры к одной небольшой сетке. Средняя разница по точкам
    // проверяет рисунок, не завися от размера исходника.
    func samples(_ image: CGImage) -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: 32 * 18 * 4)
      bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: 32, height: 18,
          bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
      }
      return bytes
    }
    let wanted = samples(expected), shown = samples(frozen)
    let error = zip(wanted, shown).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    print("KANDINSKY_VIDEO_RETURN_FRAME mean=\(Double(error) / Double(wanted.count)) saved=\(paused)")
    XCTAssertLessThan(Double(error) / Double(wanted.count), 4,
      "Returning after other videos must keep the same sharp frame before native decoder readiness")
    until = Date().addingTimeInterval(3)
    while Date() < until && !preparedOwner.active {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(preparedOwner.active, "A partial local return prepares the saved frame")
    XCTAssertFalse(preparedOwner.presented)
    let preparedPlayer = try XCTUnwrap(preparedOwner.layer.player)
    let preparedItem = try XCTUnwrap(preparedPlayer.currentItem)
    let restored = preparedPlayer.currentTime().seconds
    let saved = media.videoPlayback.position(savedKey)
    XCTAssertEqual(saved, paused, accuracy: 0.12, "The cache records the paused position")
    XCTAssertEqual(restored, saved, accuracy: 0.12, "The prepared decoder restores that position")
    XCTAssertTrue(try show(78001) === preparedOwner)
    XCTAssertTrue(preparedPlayer.currentItem === preparedItem)
    until = Date().addingTimeInterval(3)
    while Date() < until && preparedPlayer.currentTime().seconds < restored + 0.12 {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThanOrEqual(preparedPlayer.currentTime().seconds, restored + 0.12)
    scene.close()
    try await h.close()
  }

  // Открываем местный ролик вручную и сохраняем рисунок после движения. При повторном запуске
  // кадр должен оставаться видимым до восстановления позиции, а чтение с диска не выдаётся за
  // загрузку.
  func testManuallyViewedLocalVideoSavesFrameAndPositionForReopen() async throws {
    let (h, media, staged) = try await make()
    let path = "remote/" + String(repeating: "e", count: 32) + ".mp4"
    let destination = try media.fileURL(path)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: media.fileURL(staged.relativePath), to: destination)
    let attachment = Attachment(id: staged.id, relativePath: path, mime: staged.mime,
      byteSize: staged.byteSize, rawWidth: staged.rawWidth, rawHeight: staged.rawHeight,
      orientation: staged.orientation, durationMs: staged.durationMs, thumbnailKey: staged.thumbnailKey)
    let api = NetworkAPI(profile: nil)
    api.close()
    let remote = NetworkMedia(store: h.store, api: api)
    media.remotePlayback = {
      let source = try remote.playback($0, token: $1)
      guard source.localFile?.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path
      else { source.close(); throw MediaError.unavailable }
      return source
    }
    let admission = MediaAdmission(), coordinator = MediaCoordinator(admission: admission, media: media)
    let surface = InlinePlayerSurface(coordinator: coordinator)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
    root.view.addSubview(surface); surface.frame = CGRect(x: 10, y: 100, width: 320, height: 200)
    coordinator.onDetachOutput = { surface.detach() }
    defer { coordinator.close(); admission.close(); media.close(); window.isHidden = true; previous?.makeKey() }
    let key = VideoPlaybackKey(messageID: 79011, attachment: attachment)
    coordinator.play(target: PlaybackTarget(attachment: attachment, messageID: 79011, kind: .video))
    XCTAssertNil(coordinator.downloadProgress, "A local file preparing its native decoder is not a download")
    surface.attach()
    var end = Date().addingTimeInterval(5)
    while Date() < end && (!surface.hasVideoFrame || coordinator.positionMs < 700) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertNil(coordinator.lastError, "Cached original must use the local native source")
    XCTAssertTrue(surface.hasVideoFrame)
    coordinator.pause()
    let paused = coordinator.session.player.currentTime().seconds
    XCTAssertGreaterThan(paused, 0.65)
    coordinator.stop()
    let remembered = media.videoPlayback.position(key)
    XCTAssertEqual(remembered, paused, accuracy: 0.15,
      "Manual close must preserve this video's position for chat and viewer re-entry")
    let frozen = media.videoPlayback.frame(key)
    XCTAssertNotNil(frozen?.image, "Manual viewing must leave its real decoded frame, not just the old poster")
    frozen?.close()
    let videoLayer = try XCTUnwrap(surface.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
    var displayedBeforeRestore = false
    let observation = coordinator.observeChanges {
      if coordinator.nativeItemAttached, videoLayer.player != nil,
        Double(coordinator.positionMs) / 1000 < paused - 0.15
      {
        displayedBeforeRestore = true
      }
    }
    defer { coordinator.removeChangeObserver(observation) }
    coordinator.play(target: PlaybackTarget(attachment: attachment, messageID: 79011, kind: .video))
    surface.attach()
    end = Date().addingTimeInterval(5)
    while Date() < end && (!surface.hasVideoFrame || !coordinator.isReady) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    coordinator.pause()
    XCTAssertFalse(displayedBeforeRestore, "Keep the saved cover until the player reaches the remembered position")
    XCTAssertEqual(coordinator.session.player.currentTime().seconds, paused, accuracy: 0.15)
    coordinator.close(); media.close(); try await h.close()
  }

  // Сравниваем рисунки одного момента после приведения к общему размеру и сообщаем место
  // вызывающей проверки. Так отличаем кадр места остановки от первой обложки.
  private func assertDecodedFramesMatch(
    _ expected: CGImage, _ actual: CGImage, savedSeconds: Double, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    // Получаем небольшую карту цветовых каналов из кадра. Одинаковый способ пересчёта нужен для
    // сравнения с ожидаемым рисунком.
    func samples(_ image: CGImage) -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: 32 * 18 * 4)
      bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: 32, height: 18,
          bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
      }
      return bytes
    }
    let wanted = samples(expected), shown = samples(actual)
    let error = zip(wanted, shown).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    let mean = Double(error) / Double(wanted.count)
    print("KANDINSKY_VIDEO_RETURN_FRAME mean=\(mean) saved=\(savedSeconds)")
    XCTAssertLessThan(mean, 4, message, file: file, line: line)
  }

  // Даём ролику проиграться и открываем его изображение для просмотра. Проверяем, что переданный
  // кадр совпадает с позицией просмотра, которую уже успел показать проигрыватель.
  func testViewerHandoffUsesCurrentDecodedVideoFrameInsteadOfUnderlyingPoster() async throws {
    let (h, media, attachment) = try await make()
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let scene = RetainedChatScene(container: root.view.layer)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    scene.imageViewport = scene.viewport
    defer { scene.close(); media.close(); window.isHidden = true; previous?.makeKey() }
    // Вставляем ролик с заданным номером в настоящую видимую сцену. Возвращаем проигрыватель для
    // проверки кадра, переданного в отдельный просмотр.
    func show(_ id: Int64) throws -> SilentVideoPreview {
      let row = Message(id: id, chatID: 2, order: OrderKey(sortKey: id, messageID: id),
        direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "",
        replyToID: nil, revision: 1, attachments: [attachment])
      let prepared = PreparedText(message: row,
        key: TextLayoutKey(messageID: id, revision: 1, width: 320, fontSize: 17, scale: 3))
      scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [SceneFragment(
        prepared: prepared, part: 0,
        frame: CGRect(x: 12, y: 140, width: prepared.width, height: prepared.height))]))
      let node = root.view.layer.sublayers?.compactMap { $0 as? MessageLayer }.first
      return try XCTUnwrap(node?.video)
    }
    let first = try show(78001)
    var until = Date().addingTimeInterval(5)
    while Date() < until && !first.active { try await Task.sleep(nanoseconds: 20_000_000) }
    let player = try XCTUnwrap(first.layer.player), item = try XCTUnwrap(player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    until = Date().addingTimeInterval(4)
    while Date() < until && player.currentTime().seconds < 0.7 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    player.pause()
    let paused = player.currentTime().seconds
    print("KANDINSKY_VIDEO_CLOCK pause=\(paused) cache=\(media.videoPlayback.position(VideoPlaybackKey(messageID: 78001, attachment: attachment))) rate=\(player.rate)")
    XCTAssertGreaterThan(paused, 0.65)
    let buffer = try XCTUnwrap(output.copyPixelBuffer(
      forItemTime: player.currentTime(), itemTimeForDisplay: nil), "Keep a real decoded frame for an independent pixel reference")
    let reference = CIImage(cvPixelBuffer: buffer)
    let expected = try XCTUnwrap(CIContext().createCGImage(reference, from: reference.extent))
    item.remove(output)
    let handoff = try XCTUnwrap(scene.preview(78001))
    defer { handoff.close() }
    let frozen = try XCTUnwrap(handoff.image)
    assertDecodedFramesMatch(expected, frozen, savedSeconds: paused,
      "Tapping a playing video must carry its visible decoded frame into the viewer")
    scene.close()
    try await h.close()
  }

  // Первый запрос намеренно завершаем ошибкой. Повторные кадры на месте не начинают цикл
  // запросов. После ухода и возврата новый владелец может загрузить источник.
  func testFailedPreviewRetriesOnlyAfterLeavingAndReturning() async throws {
    let (h, media, attachment) = try await make()
    let file = try media.fileURL(attachment.relativePath)
    let attempts = Counter()
    media.remotePlayback = { _, _ in
      if attempts.increment() == 1 { throw MediaError.unavailable }
      return MediaPlaybackSource(file: file)
    }
    let pool = SilentVideoPreviewPool(), key = VideoPlaybackKey(messageID: 78004, attachment: attachment)
    pool.beginFrame(visibleKeys: [key], limit: 2)
    let first = try XCTUnwrap(pool.preview(key) { SilentVideoPreview(store: media) })
    // Привязываем того же владельца к нужному файлу и месту. Повторение этой команды на
    // неизменной строке проверяет отсутствие лишнего запроса.
    func bind(_ owner: SilentVideoPreview) {
      owner.bind(attachment, frame: CGRect(x: 0, y: 0, width: 300, height: 200), circular: false,
        cornerRadius: 12, bottomSquare: false, playbackKey: key)
    }
    bind(first)
    defer { pool.clear(); media.close() }
    var until = Date().addingTimeInterval(3)
    while Date() < until && (attempts.value == 0 || MediaAdmission.previewOwnerCount > 0) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(attempts.value, 1)
    for _ in 0..<10 {
      pool.beginFrame(visibleKeys: [key], limit: 2)
      let owner = try XCTUnwrap(pool.preview(key) { SilentVideoPreview(store: media) })
      XCTAssertTrue(owner === first)
      bind(owner)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(attempts.value, 1, "Failure must not start an automatic request loop")
    pool.beginFrame(visibleKeys: [], limit: 2)
    XCTAssertTrue(first.closed, "A failed owner must leave the retained set when scrolled away")
    pool.beginFrame(visibleKeys: [key], limit: 2)
    let returned = try XCTUnwrap(pool.preview(key) { SilentVideoPreview(store: media) })
    XCTAssertFalse(first === returned)
    bind(returned)
    until = Date().addingTimeInterval(3)
    while Date() < until && returned.layer.player?.currentItem == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(attempts.value, 2)
    XCTAssertNotNil(returned.layer.player?.currentItem)
    pool.clear(); media.close(); try await h.close()
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    // Считаем попытку под блокировкой и возвращаем её номер. По номеру пробный источник выбирает
    // первую ошибку или следующий успешный ответ.
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
  }

  // Заполняем ограниченный запас другими роликами, пока старый проигрыватель не освободится.
  // Возврат должен показать его сохранённый рисунок и продолжиться с прежнего времени.
  func testEvictedVideoReturnsOnItsOwnRenderedFrameAndSavedPlayhead() async throws {
    let (h, media, attachment) = try await make()
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let scene = RetainedChatScene(container: root.view.layer)
    scene.mediaStore = media
    scene.viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    scene.imageViewport = scene.viewport
    defer { scene.close(); media.close(); window.isHidden = true; previous?.makeKey() }
    // Применяем сообщение с новым номером и возвращаем владельца. Одно и то же видео в разных
    // сообщениях здесь занимает разные места запаса.
    func show(_ id: Int64) throws -> SilentVideoPreview {
      let row = Message(id: id, chatID: 2, order: OrderKey(sortKey: id, messageID: id),
        direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "",
        replyToID: nil, revision: 1, attachments: [attachment])
      let prepared = PreparedText(message: row,
        key: TextLayoutKey(messageID: id, revision: 1, width: 320, fontSize: 17, scale: 3))
      scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [SceneFragment(
        prepared: prepared, part: 0,
        frame: CGRect(x: 12, y: 140, width: prepared.width, height: prepared.height))]))
      let node = root.view.layer.sublayers?.compactMap { $0 as? MessageLayer }.first
      return try XCTUnwrap(node?.video)
    }
    let first = try show(78001)
    var until = Date().addingTimeInterval(5)
    while Date() < until && !first.active { try await Task.sleep(nanoseconds: 20_000_000) }
    let player = try XCTUnwrap(first.layer.player), item = try XCTUnwrap(player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    until = Date().addingTimeInterval(4)
    while Date() < until && player.currentTime().seconds < 0.7 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    _ = try show(78002)
    let paused = player.currentTime().seconds
    print("KANDINSKY_VIDEO_CLOCK pause=\(paused) cache=\(media.videoPlayback.position(VideoPlaybackKey(messageID: 78001, attachment: attachment))) rate=\(player.rate)")
    XCTAssertGreaterThan(paused, 0.65)
    let buffer = try XCTUnwrap(output.copyPixelBuffer(
      forItemTime: player.currentTime(), itemTimeForDisplay: nil), "Keep a real decoded frame for an independent pixel reference")
    let reference = CIImage(cvPixelBuffer: buffer)
    let expected = try XCTUnwrap(CIContext().createCGImage(reference, from: reference.extent))
    item.remove(output)
    _ = try show(78003)
    print("KANDINSKY_VIDEO_CLOCK evictedCache=\(media.videoPlayback.position(VideoPlaybackKey(messageID: 78001, attachment: attachment)))")
    XCTAssertTrue(first.closed, "The third distinct message must evict a paused decoder at the two-owner limit")
    try await Task.sleep(nanoseconds: 200_000_000)
    let returned = try show(78001)
    XCTAssertFalse(returned === first)
    let frozen = try XCTUnwrap(scene.preview(78001)?.image,
      "The first binding turn must show the saved video frame while a replacement decoder prepares")
    assertDecodedFramesMatch(expected, frozen, savedSeconds: paused,
      "Returning must show its paused decoded scene, not the video's initial poster")
    until = Date().addingTimeInterval(5)
    while Date() < until && !returned.active { try await Task.sleep(nanoseconds: 10_000_000) }
    let resumed = try XCTUnwrap(returned.layer.player).currentTime().seconds
    print("KANDINSKY_VIDEO_CLOCK returned=\(resumed) cache=\(media.videoPlayback.position(VideoPlaybackKey(messageID: 78001, attachment: attachment)))")
    XCTAssertEqual(resumed, paused, accuracy: 0.15,
      "A recreated native item must seek to this message's own paused time before presentation")
    scene.close()
    try await h.close()
  }

  // Уводим уже идущий ролик из окна и возвращаем. Проверяем прежний проигрыватель, кадр без
  // размытия, сохранённую паузу и последующее продвижение.
  func testScrollAwayAndBackKeepsNativeVideoFrameItemAndPausedPlayhead() async throws {
    let (h, media, attachment) = try await make()
    let windowScene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = windowScene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: windowScene), root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let scene = RetainedChatScene(container: root.view.layer)
    scene.mediaStore = media
    let row = Message(
      id: 77001, chatID: 2, order: OrderKey(sortKey: 1, messageID: 77001),
      direction: .incoming, savedAtMs: 0, kind: .video, text: "", caption: "",
      replyToID: nil, revision: 1, attachments: [attachment])
    let prepared = PreparedText(
      message: row, key: TextLayoutKey(messageID: row.id, revision: 1, width: 320, fontSize: 17, scale: 3))
    let fragment = SceneFragment(prepared: prepared, part: 0,
      frame: CGRect(x: 12, y: 140, width: prepared.width, height: prepared.height))
    let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)
    defer {
      scene.close()
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    // Меняем видимую область и применяем прежний снимок сцены. Ролик должен отреагировать на
    // видимость без замены сообщения.
    func show(_ viewport: CGRect) {
      scene.viewport = viewport
      scene.imageViewport = viewport
      scene.apply(SceneSnapshot(ticket: scene.ticket, fragments: [fragment]))
    }
    show(viewport)
    let node = try XCTUnwrap(root.view.layer.sublayers?.compactMap { $0 as? MessageLayer }.first)
    let owner = try XCTUnwrap(node.video)
    let until = Date().addingTimeInterval(6)
    while Date() < until && (owner.layer.player?.currentTime().seconds ?? 0) < 0.55 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let player = try XCTUnwrap(owner.layer.player), item = try XCTUnwrap(player.currentItem)
    XCTAssertTrue(owner.active, "Use a rendered native video before leaving its viewport")
    XCTAssertGreaterThan(player.currentTime().seconds, 0.5)
    let slot = try XCTUnwrap(node.image)
    let coverDeadline = Date().addingTimeInterval(3)
    while Date() < coverDeadline && (!slot.ready || slot.loading) {
      try await Task.sleep(for: .milliseconds(20))
    }
    let cover = try XCTUnwrap(slot.preview())
    XCTAssertFalse(cover.isTinyPreview)
    cover.close()
    XCTAssertFalse(slot.loading)
    let mediaTop = fragment.frame.minY + (try XCTUnwrap(prepared.mediaRect)).minY
    show(CGRect(x: 0, y: mediaTop - viewport.height - 40, width: viewport.width,
      height: viewport.height))
    XCTAssertTrue(node.image === slot, "A nearby video must keep its ready cover layer")
    XCTAssertNil(node.video, "The off-screen cover needs no active video layer")
    show(viewport)
    XCTAssertTrue(node.image === slot, "Reversing to nearby media reuses the ready cover")
    show(viewport.offsetBy(dx: 0, dy: 2000))
    XCTAssertFalse(owner.closed, "Leaving autoplay visibility must pause, not destroy, a retained video")
    XCTAssertTrue(owner.layer.player === player)
    XCTAssertTrue(player.currentItem === item)
    try await Task.sleep(nanoseconds: 100_000_000)
    let paused = player.currentTime().seconds
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.08)
    show(viewport)
    XCTAssertTrue(node.video === owner, "First return must reuse the same rendered output")
    XCTAssertTrue(owner.layer.player === player && player.currentItem === item)
    XCTAssertTrue(owner.active)
    XCTAssertEqual(owner.layer.opacity, 1, "Do not expose the tiny while an owned native frame exists")
    try await Task.sleep(nanoseconds: 180_000_000)
    XCTAssertGreaterThan(player.currentTime().seconds, paused + 0.08)
    scene.close()
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    try await h.close()
  }

  // Проверяем, что поверхность состоит из слоя ролика и одного изображения и не забирает касания.
  // Так дополнительный вид не закроет видео или жесты ленты.
  func testVideoSurfaceContainsOnlyVideoAndPoster() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media),
      surface = InlinePlayerSurface(coordinator: c)
    surface.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
    surface.update()
    surface.layoutIfNeeded()
    XCTAssertEqual(surface.subviews.count, 1)
    XCTAssertTrue(surface.subviews.first is UIImageView)
    XCTAssertTrue(surface.layer.sublayers?.contains { $0 is AVPlayerLayer } == true)
    XCTAssertFalse(surface.isUserInteractionEnabled)
    surface.detach()
    c.close()
    media.close()
    admission.close()
    try await h.close()
  }
  // Пытаемся открыть неподдержанное звуковое вложение. Проигрыватель должен отказать, не занимая
  // место и сохраняя выключенный звук.
  func testAudioCannotOpenPlayerOrEnableSound() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media)
    let audio = Attachment(
      id: "unsupported-audio", relativePath: "objects/absent.m4a", mime: "audio/mp4", byteSize: 42,
      rawWidth: 0, rawHeight: 0, orientation: 1, durationMs: 1000, thumbnailKey: "")
    XCTAssertTrue(c.session.player.isMuted)
    c.play(target: PlaybackTarget(attachment: audio, messageID: 4401, kind: .voice))
    XCTAssertNil(c.currentTarget)
    XCTAssertEqual(c.lastError as? MediaError, .unavailable)
    XCTAssertEqual(c.activePlayerCount, 0)
    XCTAssertTrue(c.session.player.isMuted)
    c.close()
    media.close()
    admission.close()
    try await h.close()
  }

  // Проверяем, что исходник содержит звук, затем ждём два настоящих повтора без звука и пробуем
  // перемотать на паузе. При остановке активный файл должен полностью отсоединиться.
  func testMutedRoundLoopsAcrossNativeEndAndKeepsPauseSeekAndOneOwner() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission(),
      c = MediaCoordinator(admission: admission, media: media)
    defer {
      c.close()
      media.close()
      admission.close()
    }
    let audio = try await AVURLAsset(url: media.fileURL(a.relativePath)).loadTracks(
      withMediaType: .audio)
    XCTAssertFalse(audio.isEmpty, "The round fixture must contain actual AAC audio")
    let ready = expectation(description: "Беззвучное круглое видео готово"),
      twice = expectation(description: "Two complete native round loops")
    ready.assertForOverFulfill = false
    twice.assertForOverFulfill = false
    var wraps = 0, last: Int64 = 0, peak = 0
    let identity = c.platformPlayerIdentity
    c.onChange = {
      peak = max(peak, c.activePlayerCount)
      if c.isReady { ready.fulfill() }
      guard c.isReady, c.isPlaying else { return }
      let position = c.positionMs
      if last > 1400, position < 500 {
        wraps += 1
        if wraps >= 2 { twice.fulfill() }
      }
      last = position
    }
    c.play(target: PlaybackTarget(attachment: a, messageID: 991, kind: .round))
    await fulfillment(of: [ready], timeout: 5)
    XCTAssertTrue(c.session.player.isMuted)
    XCTAssertGreaterThan(c.session.player.volume, 0)
    await fulfillment(of: [twice], timeout: 8.5)
    XCTAssertGreaterThanOrEqual(
      wraps, 2, "A loop flag is insufficient: native time must cross the end twice")
    XCTAssertEqual(c.platformPlayerIdentity, identity)
    XCTAssertEqual(peak, 1)
    guard wraps >= 2 else {
      try await h.close()
      return
    }
    c.pause()
    try await Task.sleep(nanoseconds: 150_000_000)
    let paused = c.positionMs
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(c.positionMs, paused, accuracy: 80)
    XCTAssertFalse(c.isPlaying)
    let sought = expectation(description: "Paused round seek completed")
    c.seek(ms: 1600) { done in
      XCTAssertTrue(done)
      sought.fulfill()
    }
    await fulfillment(of: [sought], timeout: 3)
    XCTAssertFalse(c.isPlaying)
    XCTAssertEqual(c.positionMs, 1600, accuracy: 120)
    let again = expectation(description: "Round loops after paused seek")
    last = c.positionMs
    c.onChange = {
      guard c.isReady, c.isPlaying else { return }
      let position = c.positionMs
      if last > 1400, position < 500 { again.fulfill() }
      last = position
    }
    c.resume()
    await fulfillment(of: [again], timeout: 3)
    c.stop()
    XCTAssertEqual(c.activePlayerCount, 0)
    XCTAssertNil(c.session.player.currentItem)
    try await h.close()
  }

  // Открываем местное круглое видео в ленте и сравниваем его высоту и положение следующего
  // сообщения после остановки. В истории не должно остаться пустого зазора.
  func testCachedRoundPlaybackKeepsRowAndFollowingMessageStable() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission(),
      c = MediaCoordinator(admission: admission, media: media), host = ChatScrollHost()
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    defer {
      host.close()
      c.close()
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    let draft = AttachmentDraft(
      id: a.id, relativePath: a.relativePath, mime: a.mime, byteSize: a.byteSize,
      rawWidth: a.rawWidth, rawHeight: a.rawHeight, orientation: 1, durationMs: a.durationMs)
    let roundDelta = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .round, attachments: [draft]))
    let nextDelta = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, text: "after-round-height-oracle"))
    let round = try XCTUnwrap(roundDelta.inserted.first),
      next = try XCTUnwrap(nextDelta.inserted.first)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(host)
    host.frame = CGRect(x: 10, y: 80, width: 360, height: 560)
    host.configureMedia(media)
    host.configurePlayback(c, media: media)
    host.layoutIfNeeded()
    try await host.open(chatID: 2, repository: h.repo, anchor: nil)
    host.setMediaVisible(true)
    // Ищем подготовленную строку нужного круглого видео во вложенных слоях. Замер берёт
    // координаты именно этой строки.
    func roundLayout(_ layer: CALayer) -> PreparedText? {
      if let node = layer as? MessageLayer, let fragment = node.fragment,
        fragment.id.messageID == round.id
      {
        return fragment.prepared
      }
      for child in layer.sublayers ?? [] { if let result = roundLayout(child) { return result } }
      return nil
    }
    // Ждём, когда заданное состояние проигрывателя или ленты появится, с предельным сроком.
    // Дальнейшие сравнения выполняем после применения изменения.
    func settled(_ check: () -> Bool, seconds: Double = 5) async throws -> Bool {
      let end = Date().addingTimeInterval(seconds)
      while Date() < end {
        if check() { return true }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      return check()
    }
    let initial = try await settled {
      roundLayout(host.layer) != nil && host.loadedCount == 2
    }
    XCTAssertTrue(initial)
    guard initial else {
      try await h.close()
      return
    }
    let compact = try XCTUnwrap(roundLayout(host.layer)),
      index = try XCTUnwrap(
        Mirror(reflecting: host).children.first { $0.label == "index" }?.value as? HistoryIndex)
    let compactHeight = try XCTUnwrap(index.height(of: round.id)),
      followingTop = try XCTUnwrap(index.top(of: next.id))
    XCTAssertEqual(compactHeight, Double(compact.height + 4), accuracy: 0.5)
    var states: [[String: Any]] = []
    for cycle in 0..<3 {
      c.play(
        target: PlaybackTarget(
          attachment: round.attachments[0], messageID: round.id, kind: .round))
      let ready = try await settled { c.isReady && c.isPlaying }
      XCTAssertTrue(ready, "Cycle \(cycle): real native video must start")
      guard ready else { break }
      try await Task.sleep(nanoseconds: 150_000_000)
      XCTAssertTrue(roundLayout(host.layer) === compact, "Playback keeps the same retained layout")
      XCTAssertEqual(index.height(of: round.id) ?? -1, compactHeight, accuracy: 0.5)
      XCTAssertEqual(index.top(of: next.id) ?? -1, followingTop, accuracy: 0.5)
      c.pause()
      XCTAssertEqual(c.activePlayerCount, 1)
      c.stop()
      let restored = try await settled(
        {
          roundLayout(host.layer) === compact
            && abs((index.height(of: round.id) ?? 0) - compactHeight) < 0.5
        }, seconds: 1)
      states.append([
        "cycle": cycle, "compactHeight": compactHeight,
        "indexedAfterStop": index.height(of: round.id) ?? -1, "followingBefore": followingTop,
        "followingAfter": index.top(of: next.id) ?? -1
      ])
      XCTAssertTrue(
        roundLayout(host.layer) === compact,
        "Reuse the retained compact layout, not a replacement that masks the bug")
      XCTAssertTrue(restored, "Cached compact drawing must also restore indexed height")
      XCTAssertEqual(index.height(of: round.id) ?? -1, compactHeight, accuracy: 0.5)
      XCTAssertEqual(
        index.top(of: next.id) ?? -1, followingTop, accuracy: 0.5,
        "The next message must return without a retained expansion gap")
      XCTAssertEqual(c.activePlayerCount, 0)
      if !restored { break }
    }
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    try JSONSerialization.data(
      withJSONObject: ["cycles": states], options: [.prettyPrinted, .sortedKeys]
    ).write(to: base.appendingPathComponent("kandinsky-round-cached-height.json"), options: .atomic)
    try await h.close()
  }

  // Ждём окончания обычного видео и проверяем остановку при сохранённом источнике. Затем
  // перематываем и убеждаемся, что повтор действительно двигается вперёд.
  func testRegularVideoEndsWithoutLoopingAndCanSeekToReplay() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission(),
      c = MediaCoordinator(admission: admission, media: media)
    defer {
      c.close()
      media.close()
      admission.close()
    }
    let ready = expectation(description: "Regular video ready")
    ready.assertForOverFulfill = false
    c.onChange = { if c.isReady { ready.fulfill() } }
    c.play(target: PlaybackTarget(attachment: a, messageID: 992, kind: .video))
    await fulfillment(of: [ready], timeout: 5)
    try await Task.sleep(nanoseconds: 2_600_000_000)
    XCTAssertFalse(c.isPlaying, "Regular video must finish once")
    XCTAssertTrue(c.isReady, "Completion retains the ready native item for replay")
    XCTAssertGreaterThanOrEqual(
      c.positionMs, 1800, "Regular video must remain at its end, not silently loop or lose its item"
    )
    let sought = expectation(description: "Completed video seeks for replay")
    c.seek(ms: 400) { done in
      XCTAssertTrue(done)
      sought.fulfill()
    }
    await fulfillment(of: [sought], timeout: 3)
    XCTAssertEqual(c.positionMs, 400, accuracy: 120)
    let advanced = expectation(description: "Replayed video advances beyond the seek position")
    var delivered = false
    c.onChange = {
      if c.isPlaying, c.positionMs > 600, !delivered {
        delivered = true
        advanced.fulfill()
      }
    }
    c.resume()
    await fulfillment(of: [advanced], timeout: 5)
    XCTAssertTrue(c.isPlaying)
    XCTAssertGreaterThan(c.positionMs, 600)
    c.stop()
    try await h.close()
  }

  // Запускаем беззвучный предпросмотр и ловим два сброса времени на границе файла. Звуковых
  // дорожек в источнике показа быть не должно, а снятие владельца гасит прежний вывод.
  func testMutedRoundPreviewCrossesTwoNativeEndsWithoutAudioOrExtraOwners() async throws {
    let (h, media, a) = try await make()
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController(), owner = SilentVideoPreview(store: media)
    defer {
      owner.close()
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.layer.addSublayer(owner.layer)
    owner.bind(
      a, frame: CGRect(x: 20, y: 100, width: 212, height: 212), circular: true, cornerRadius: 0,
      bottomSquare: false)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && !owner.active { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(owner.active)
    let player = try XCTUnwrap(owner.layer.player), item = try XCTUnwrap(player.currentItem)
    XCTAssertTrue(player.isMuted)
    XCTAssertEqual(player.volume, 0)
    let audio = try await item.asset.loadTracks(withMediaType: .audio)
    XCTAssertTrue(audio.isEmpty)
    var last = 0.0, wraps = 0
    let end = Date().addingTimeInterval(8.5)
    while Date() < end && wraps < 2 {
      let position = player.currentTime().seconds
      if last > 1.4, position < 0.5 { wraps += 1 }
      last = position
      XCTAssertEqual(MediaAdmission.previewOwnerCount, 1)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(wraps, 2, "Muted preview must cross two native end boundaries")
    owner.close()
    XCTAssertNil(owner.layer.player)
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(player.rate, 0)
    try await h.close()
  }

  // Занимаем два места предпросмотра, затем меняем источник одного. Старый слой и проигрыватель
  // этого файла освобождаются, а сосед продолжает работу.
  func testChangingSourceWithBothPreviewSlotsOccupiedRetiresOldNativeOutput() async throws {
    let (h, media, a) = try await make()
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let owners = [SilentVideoPreview(store: media), SilentVideoPreview(store: media)]
    defer {
      owners.forEach { $0.close() }
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/video-00.mp4")
    let draft = try await media.stage(sourceURL: fixture, mime: "video/mp4")
    let next = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: 1,
      durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey)
    XCTAssertNotEqual(next.relativePath, a.relativePath)
    for (n, owner) in owners.enumerated() {
      root.view.layer.addSublayer(owner.layer)
      owner.bind(
        a, frame: CGRect(x: 10 + n * 180, y: 100, width: 170, height: 170), circular: n == 0,
        cornerRadius: 12, bottomSquare: false)
    }
    let until = Date().addingTimeInterval(5)
    while Date() < until && !owners.allSatisfy({ $0.active }) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(owners.allSatisfy { $0.active })
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 2)
    owners[0].bind(
      next, frame: owners[0].layer.frame, circular: true, cornerRadius: 12, bottomSquare: false)
    XCTAssertTrue(
      owners[0].closed,
      "A changed source must retire its previous native owner even when both slots are occupied")
    XCTAssertNil(
      owners[0].layer.player,
      "A revised message must never retain the old native source above its new poster")
    XCTAssertNil(owners[0].layer.superlayer)
    XCTAssertTrue(owners[1].active)
    owners.forEach { $0.close() }
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    try await h.close()
  }
  // Сто раз готовим первый настоящий кадр и закрываем предпросмотр. Считаем полученные и закрытые
  // кадры, проверяем отсутствие звука, ограниченный пик владельцев и нулевой расход в конце.
  func testHundredSilentNativePreviewLifecyclesReleaseOwnersAndOutputs() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission()
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    var frames = 0, closed = 0, captures = 0, peak = 0
    for cycle in 0..<100 {
      var owner: SilentVideoPreview? = SilentVideoPreview(store: media)
      weak var retired = owner
      let layer = try XCTUnwrap(owner?.layer)
      root.view.layer.addSublayer(layer)
      owner?.bind(
        a, frame: CGRect(x: 10, y: 100, width: 180, height: 180), circular: cycle % 2 == 0,
        cornerRadius: 12, bottomSquare: false)
      let ready = Date().addingTimeInterval(5)
      while Date() < ready && owner?.active != true {
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      XCTAssertTrue(owner?.active == true, "Native first-frame readiness in cycle \(cycle)")
      let player = try XCTUnwrap(layer.player), item = try XCTUnwrap(player.currentItem)
      XCTAssertTrue(player.isMuted)
      XCTAssertTrue(item.asset.tracks(withMediaType: .audio).isEmpty)
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
      item.add(output)
      var copied = false
      let until = Date().addingTimeInterval(2)
      while Date() < until && !copied {
        if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil
        {
          copied = true
          frames += 1
        } else {
          try await Task.sleep(nanoseconds: 20_000_000)
        }
      }
      XCTAssertTrue(copied, "A fresh decoded native frame in cycle \(cycle)")
      item.remove(output)
      peak = max(peak, MediaAdmission.previewOwnerCount)
      if cycle % 3 == 0 {
        let capture: CaptureLease = try await withCheckedThrowingContinuation { continuation in
          _ = admission.acquire(.photo) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
        capture.release()
        captures += 1
      } else if cycle % 3 == 1 {
        media.trimMemory()
      } else {
        owner?.close()
      }
      owner = nil
      let drained = Date().addingTimeInterval(1)
      while Date() < drained && (retired != nil || MediaAdmission.previewOwnerCount != 0) {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertNil(retired, "The actual preview owner must deallocate in cycle \(cycle)")
      XCTAssertNil(layer.player)
      XCTAssertNil(layer.superlayer)
      XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
      closed += 1
    }
    media.close()
    let drained = Date().addingTimeInterval(1)
    while Date() < drained && media.bytesUsed != 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(media.bytesUsed, 0)
    XCTAssertEqual(frames, 100)
    XCTAssertEqual(closed, 100)
    XCTAssertLessThanOrEqual(peak, 2)
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    try JSONSerialization.data(
      withJSONObject: [
        "cycles": closed, "nativeFramesVerified": frames, "captureRetirements": captures,
        "peakPreviewOwners": peak, "remainingPreviewOwners": MediaAdmission.previewOwnerCount,
        "forcedGC": false, "scope": "iOS Simulator actual AVPlayerLayer lifecycle"
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: base.appendingPathComponent("kandinsky-preview-hundred.json"), options: .atomic)
    try await h.close()
  }
  // Показываем обычный и круглый ролики в видимой ленте и проверяем меняющиеся беззвучные кадры.
  // При переходе к ручному показу прежние владельцы освобождают места.
  func testVisibleRoundAndVideoAutoplayMutedActualFramesAndRetireBeforeManualPlayer() async throws {
    print("SILENT_SETUP before-stage")
    let (h, media, a) = try await make(), admission = MediaAdmission(), host = ChatScrollHost(),
      root = UIViewController()
    let c = MediaCoordinator(admission: admission, media: media)
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    defer {
      host.close()
      c.close()
      media.close()
      admission.close()
      window.isHidden = true
      previous?.makeKey()
    }
    print("SILENT_SETUP staged-window-created")
    let draft = AttachmentDraft(
      id: a.id, relativePath: a.relativePath, mime: a.mime, byteSize: a.byteSize,
      rawWidth: a.rawWidth, rawHeight: a.rawHeight, orientation: 1, durationMs: a.durationMs)
    let round = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .round, attachments: [draft]))
    print("SILENT_SETUP round-saved")
    let next = AttachmentDraft(
      id: UUID().uuidString, relativePath: draft.relativePath, mime: draft.mime,
      byteSize: draft.byteSize, rawWidth: draft.rawWidth, rawHeight: draft.rawHeight,
      orientation: 1, durationMs: draft.durationMs)
    _ = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .video, attachments: [next]))
    print("SILENT_SETUP video-saved")
    root.view = host
    window.rootViewController = root
    window.makeKeyAndVisible()
    host.frame = window.bounds
    host.configureMedia(media)
    host.configurePlayback(c, media: media)
    print("SILENT_SETUP window-visible")
    try await host.open(chatID: 2, repository: h.repo, anchor: nil)
    host.setMediaVisible(true)
    print("SILENT_SETUP history-opened")
    // Обходим дерево и возвращаем только слои системного проигрывателя. Так измеряем количество
    // фактических выводов, даже если они вложены в область строки.
    func outputs(_ layer: CALayer) -> [AVPlayerLayer] {
      (layer.sublayers ?? []).flatMap { child in
        (child as? AVPlayerLayer).map { [$0] } ?? outputs(child)
      }
    }
    let category = AVAudioSession.sharedInstance().category
    let deadline = Date().addingTimeInterval(5)
    var layers: [AVPlayerLayer] = []
    while Date() < deadline {
      layers = outputs(host.layer).filter { $0.player?.currentItem != nil && $0.isReadyForDisplay }
      if layers.count == 2 { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(
      layers.count, 2,
      "Visible round and video must create actual native outputs without a user play call")
    guard layers.count == 2 else {
      try await h.close()
      return
    }
    XCTAssertTrue(layers.allSatisfy { $0.player?.isMuted == true })
    XCTAssertEqual(AVAudioSession.sharedInstance().category, category)
    for layer in layers {
      let player = try XCTUnwrap(layer.player), item = try XCTUnwrap(player.currentItem)
      XCTAssertTrue(
        item.asset.tracks(withMediaType: .audio).isEmpty,
        "Silent previews must not attach an audio track to the native player")
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
      item.add(output)
      var hashes = Set<String>()
      let end = Date().addingTimeInterval(3)
      while Date() < end && hashes.count < 3 {
        if let pixels = output.copyPixelBuffer(
          forItemTime: player.currentTime(), itemTimeForDisplay: nil)
        {
          CVPixelBufferLockBaseAddress(pixels, .readOnly)
          if let address = CVPixelBufferGetBaseAddress(pixels) {
            let data = Data(
              bytes: address,
              count: CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
            hashes.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
          }
          CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      item.remove(output)
      XCTAssertGreaterThanOrEqual(
        hashes.count, 3, "The visible native output must contain changing decoded frames")
    }
    // Находим узлы сообщений в дереве, чтобы проверить положение картинки под живым видео. Обход
    // не считает сам проигрыватель узлом текста.
    func messageNodes(_ layer: CALayer) -> [MessageLayer] {
      (layer.sublayers ?? []).flatMap { child in
        (child as? MessageLayer).map { [$0] } ?? messageNodes(child)
      }
    }
    let nodes = messageNodes(host.layer).filter { $0.video?.active == true }
    let postersReady = Date().addingTimeInterval(5)
    while Date() < postersReady && !nodes.allSatisfy({ $0.image?.ready == true }) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(nodes.count, 2)
    XCTAssertTrue(nodes.allSatisfy { $0.image?.ready == true })
    XCTAssertTrue(
      nodes.allSatisfy { $0.image?.layer.isHidden == true },
      "An opaque ready native output must not redraw its covered poster")
    let stored = try XCTUnwrap(
      Mirror(reflecting: host).children.first { $0.label?.hasSuffix("scene") == true }?.value)
    let retained = try XCTUnwrap(
      (stored as? RetainedChatScene) ?? Mirror(reflecting: stored).children.first?.value
        as? RetainedChatScene)
    for node in nodes {
      let f = try XCTUnwrap(node.fragment), rect = try XCTUnwrap(f.prepared.mediaRect),
        image = try XCTUnwrap(node.image)
      image.bind(
        a, frame: rect, circular: f.prepared.message.kind == .round, maxPixel: 512,
        kind: f.prepared.message.kind)
      XCTAssertTrue(
        image.loading, "Exercise an actual asynchronous poster upgrade below a ready native output")
      XCTAssertFalse(
        retained.performLoadAction(
          at: CGPoint(x: node.frame.minX + rect.midX, y: node.frame.minY + rect.midY)),
        "An invisible loading control below a ready video must not consume its playback tap")
    }
    let capture: CaptureLease = try await withCheckedThrowingContinuation { continuation in
      _ = admission.acquire(.photo) { continuation.resume(with: $0) }
    }
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    XCTAssertTrue(
      nodes.allSatisfy { $0.image?.layer.isHidden == false },
      "Retiring a native output must restore its retained poster before capture is granted")
    capture.release()
    let selected = try XCTUnwrap(round.inserted.first),
      ready = expectation(description: "manual player after silent retirement")
    ready.assertForOverFulfill = false
    c.onChange = { if c.isReady { ready.fulfill() } }
    c.play(target: PlaybackTarget(attachment: a, messageID: selected.id, kind: .round))
    await fulfillment(of: [ready], timeout: 8)
    XCTAssertEqual(MediaAdmission.previewOwnerCount, 0)
    XCTAssertEqual(c.activePlayerCount, 1)
    host.setMediaVisible(false)
    c.stop()
    try await h.close()
  }

  // Открываем временную историю и переносим проверочный файл в обычное хранилище медиа.
  // Возвращаем все нужные части, чтобы сценарий мог после себя закрыть их.
  private func make(mime: String = "video/mp4") async throws -> (
    RepositoryHarness, MediaStore, Attachment
  ) {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let corpus = Bundle(for: RepositoryHarness.self).url(
      forResource: "fixtures", withExtension: nil)!
    let json =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: corpus.appendingPathComponent("manifest.json"))) as! [String: Any]
    let file =
      (json["files"] as! [[String: Any]]).first { $0["mime"] as? String == mime }!["fileName"]
      as! String
    let d = try await media.stage(
      sourceURL: corpus.appendingPathComponent("media/" + file), mime: mime)
    return (
      h, media,
      Attachment(
        id: d.id, relativePath: d.relativePath, mime: d.mime, byteSize: d.byteSize,
        rawWidth: d.rawWidth, rawHeight: d.rawHeight, orientation: d.orientation,
        durationMs: d.durationMs, thumbnailKey: d.thumbnailKey)
    )
  }
  // Подаём подтверждение с тем же местным файлом, затем редакцию с другим источником. Первый
  // ответ сохраняет воспроизведение, второй прекращает показ старого файла.
  func testHigherRevisionStopsReplacedSourceButAcknowledgementKeepsTheSameLocalFile() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media)
    defer {
      c.close()
      media.close()
      admission.close()
    }
    let ready = expectation(description: "actual source ready")
    ready.assertForOverFulfill = false
    c.onChange = { if c.isReady { ready.fulfill() } }
    c.play(target: PlaybackTarget(attachment: a, messageID: 90, kind: .video))
    await fulfillment(of: [ready], timeout: 8)
    c.pause()
    let chat = ChatSummary(
      id: 2, title: "source", lastPreview: "", lastSortKey: 1, lastSavedAtMs: 1, unreadCount: 0,
      pinned: false)
    // Строим изменение сообщения с переданным вложением. Так в проверке меняется источник, а
    // номер воспроизведения остаётся узнаваемым.
    func update(_ attachment: Attachment) -> MessageDelta {
      MessageDelta(
        updated: [
          Message(
            id: 90, chatID: 2, order: OrderKey(sortKey: 1, messageID: 90), direction: .outgoing,
            savedAtMs: 1, kind: .video, text: "", caption: "", replyToID: nil, revision: 2,
            attachments: [attachment])
        ], chat: chat, reason: .sync)
    }
    let ack = Attachment(
      id: "acknowledged-id", relativePath: a.relativePath, mime: a.mime, byteSize: a.byteSize,
      rawWidth: a.rawWidth, rawHeight: a.rawHeight, orientation: a.orientation,
      durationMs: a.durationMs, thumbnailKey: "ack")
    c.apply(update(ack))
    XCTAssertEqual(
      c.activePlayerCount, 1, "Acknowledgement may rename an attachment without replacing its file")
    let replacement = Attachment(
      id: ack.id, relativePath: "remote/replaced.mp4", mime: a.mime, byteSize: a.byteSize,
      rawWidth: a.rawWidth, rawHeight: a.rawHeight, orientation: a.orientation,
      durationMs: a.durationMs, thumbnailKey: "new")
    c.apply(update(replacement))
    XCTAssertNil(c.currentMessageID, "A revised blob must not keep playing stale content")
    XCTAssertEqual(c.activePlayerCount, 0)
    try await h.close()
  }
  // Открываем видео, перематываем и меняем активный запрос. Незакрытый проигрыватель не должен
  // пропустить камеру, а после снятия вывода она получает место.
  func testSingleNativeOwnerSeekSwitchAndCaptureWaitForStop() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission()
    let coordinator = MediaCoordinator(admission: admission, media: media)
    let ready = expectation(description: "native AVPlayer ready")
    ready.assertForOverFulfill = false
    coordinator.onChange = {
      if coordinator.isReady, coordinator.currentMessageID == 1 { ready.fulfill() }
    }
    coordinator.play(target: PlaybackTarget(attachment: a, messageID: 1))
    await fulfillment(of: [ready], timeout: 8)
    let playerID = coordinator.platformPlayerIdentity
    XCTAssertEqual(coordinator.activePlayerCount, 1)
    XCTAssertEqual(coordinator.durationMs, 2000, accuracy: 80)
    let seek = expectation(description: "native seek")
    coordinator.seek(ms: 1200) { finished in
      XCTAssertTrue(finished)
      seek.fulfill()
    }
    await fulfillment(of: [seek], timeout: 3)
    coordinator.pause()
    XCTAssertFalse(coordinator.isPlaying)
    XCTAssertEqual(coordinator.positionMs, 1200, accuracy: 100)
    let latest = expectation(description: "latest target wins")
    latest.assertForOverFulfill = false
    coordinator.onChange = {
      if coordinator.isReady, coordinator.currentMessageID == 3 { latest.fulfill() }
    }
    coordinator.play(target: PlaybackTarget(attachment: a, messageID: 2))
    coordinator.play(target: PlaybackTarget(attachment: a, messageID: 3))
    await fulfillment(of: [latest], timeout: 8)
    XCTAssertEqual(coordinator.platformPlayerIdentity, playerID)
    XCTAssertEqual(coordinator.activePlayerCount, 1)
    let capture = expectation(description: "capture granted only after native output detached")
    admission.acquire(.photo) { result in
      if case let .success(lease) = result {
        XCTAssertEqual(coordinator.activePlayerCount, 0)
        XCTAssertFalse(coordinator.nativeItemAttached)
        lease.release()
      } else {
        XCTFail("Capture denied after player stop")
      }
      capture.fulfill()
    }
    await fulfillment(of: [capture], timeout: 3)
    coordinator.close()
    media.close()
    admission.close()
    try await h.close()
  }
  // Закрываем подготовку после появления системного источника и до готовности. Поздний ответ не
  // запускает показ. Место освобождается для камеры.
  func testCloseDuringPendingNativePreparationCannotResume() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission()
    let coordinator = MediaCoordinator(admission: admission, media: media)
    let began = expectation(description: "actual native item attached before close")
    var didClose = false
    coordinator.onChange = {
      if coordinator.nativeItemAttached, !didClose {
        XCTAssertFalse(coordinator.isReady)
        didClose = true
        coordinator.close()
        began.fulfill()
      }
    }
    coordinator.play(target: PlaybackTarget(attachment: a, messageID: 1))
    await fulfillment(of: [began], timeout: 5)
    let capture = expectation(description: "pending playback cancelled")
    admission.acquire(.photo) { result in
      if case let .success(lease) = result {
        lease.release()
      } else {
        XCTFail("Pending player reservation leaked")
      }
      capture.fulfill()
    }
    await fulfillment(of: [capture], timeout: 3)
    XCTAssertEqual(coordinator.activePlayerCount, 0)
    XCTAssertFalse(coordinator.nativeItemAttached)
    XCTAssertFalse(coordinator.isPlaying)
    media.close()
    admission.close()
    try await h.close()
  }

  // Убираем играющее сообщение из доступной истории. Согласование ленты должно снять его источник
  // и сократить число владельцев до нуля.
  func testMissingPlaybackMessageStopsNativeOwner() async throws {
    let (h, media, a) = try await make(mime: "video/mp4"), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media), host = ChatScrollHost()
    host.configurePlayback(c, media: media)
    let ready = expectation(description: "real native player prepared")
    ready.assertForOverFulfill = false
    c.onChange = { if c.isReady { ready.fulfill() } }
    c.play(target: PlaybackTarget(attachment: a, messageID: 987654321))
    await fulfillment(of: [ready], timeout: 8)
    XCTAssertEqual(c.activePlayerCount, 1)
    let retired = expectation(description: "native player item detached after scene reconciliation")
    retired.assertForOverFulfill = false
    c.onChange = { [weak c] in if c?.nativeItemAttached == false { retired.fulfill() } }
    let retirementStart = ProcessInfo.processInfo.systemUptime
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    host.setNeedsLayout()
    host.layoutIfNeeded()
    await fulfillment(of: [retired], timeout: 2)
    print(
      "KANDINSKY_MISSING_PLAYER retirementMs=\((ProcessInfo.processInfo.systemUptime-retirementStart)*1000)"
    )
    XCTAssertFalse(c.nativeItemAttached, "An absent message must detach its player")
    XCTAssertEqual(c.activePlayerCount, 0)
    host.close()
    c.close()
    media.close()
    admission.close()
    try await h.close()
  }

  func testInvalidVideoReleasesTheNativePlayerBeforeTheNextResult() async throws {
    let (harness, media, original) = try await make()
    let admission = MediaAdmission()
    let playback = MediaCoordinator(admission: admission, media: media)
    defer {
      playback.close()
      media.close()
      admission.close()
    }
    let badPath = "objects/incomplete.mp4"
    let bytes = Data([0, 0, 0, 32])
    try bytes.write(to: media.fileURL(badPath))
    let bad = Attachment(
      id: "incomplete", relativePath: badPath, mime: "video/mp4", byteSize: Int64(bytes.count),
      rawWidth: 256, rawHeight: 256, orientation: 1, durationMs: 6_000, thumbnailKey: "incomplete")
    let rejected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      playback.lastError != nil && !playback.nativeItemAttached && playback.currentMessageID == nil
    }, object: nil)
    playback.play(target: PlaybackTarget(attachment: bad, messageID: 1, kind: .video), localOnly: true)
    await fulfillment(of: [rejected], timeout: 6)
    XCTAssertEqual(playback.activePlayerCount, 0)

    let invalidRound = PlaybackTarget(attachment: bad, messageID: 3, kind: .round)
    playback.play(target: invalidRound, localOnly: true)
    let rejectedRound = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      playback.lastError != nil && playback.currentTarget == invalidRound
    }, object: nil)
    await fulfillment(of: [rejectedRound], timeout: 6)
    XCTAssertEqual(playback.activePlayerCount, 0)

    let next = PlaybackTarget(attachment: original, messageID: 2, kind: .video)
    playback.play(target: next, localOnly: true)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      playback.isReady && playback.currentTarget == next && playback.durationMs > 0
    }, object: nil)
    await fulfillment(of: [ready], timeout: 8)
    XCTAssertNil(playback.lastError)
    let chats = try await harness.repo.chats(matching: "")
    playback.apply(MessageDelta(removedIDs: [next.messageID], chat: try XCTUnwrap(chats.first)))
    XCTAssertNil(playback.currentTarget)
    XCTAssertFalse(playback.nativeItemAttached)
    XCTAssertEqual(playback.activePlayerCount, 0)
    try await harness.close()
  }

  // Запускаем уточнение качества у видимого файла. Старый рисунок должен оставаться доступен,
  // пока новый ещё готовится.
  func testThumbnailQualityUpgradeKeepsDisplayedPreview() async throws {
    let (h, media, a) = try await make()
    defer { media.close() }
    let slot = MediaImageSlot(store: media)
    defer { slot.close() }
    let ready = expectation(description: "initial preview displayed")
    ready.assertForOverFulfill = false
    slot.onReady = { if slot.ready { ready.fulfill() } }
    slot.bind(a, frame: CGRect(x: 0, y: 0, width: 240, height: 240), maxPixel: 320)
    await fulfillment(of: [ready], timeout: 8)
    slot.bind(a, frame: CGRect(x: 0, y: 0, width: 320, height: 320), maxPixel: 512)
    XCTAssertTrue(
      slot.ready, "A quality upgrade of the same media must retain the displayed preview")
    try await h.close()
  }

  // Задерживаем получение оригинала и проверяем, что проигрыватель уже знает номер сообщения. По
  // этому номеру можно отменить работу до появления кадра.
  func testPendingMediaHasCancellableIdentityBeforeOriginalFinishes() async throws {
    let (h, media, a) = try await make(), admission = MediaAdmission()
    let c = MediaCoordinator(admission: admission, media: media), gate = DispatchSemaphore(value: 0)
    let entered = expectation(description: "download has started"),
      cancelled = expectation(description: "source load was cancelled")
    let url = try media.fileURL(a.relativePath)
    media.remoteFile = { _, _, token in
      entered.fulfill()
      gate.wait()
      if token.isCancelled {
        cancelled.fulfill()
        throw MediaError.cancelled
      }
      return (url, a.mime)
    }
    c.play(target: PlaybackTarget(attachment: a, messageID: 84))
    await fulfillment(of: [entered], timeout: 3)
    XCTAssertEqual(
      c.currentMessageID, 84,
      "Pending media must be identifiable so the row can expose progress and cancellation")
    c.stop()
    gate.signal()
    XCTAssertNil(c.currentMessageID)
    XCTAssertEqual(c.activePlayerCount, 0)
    await fulfillment(of: [cancelled], timeout: 3)
    c.close()
    media.close()
    admission.close()
    try await h.close()
  }

  func testCancelledOriginalReadCannotPublishALateFile() async throws {
    let (harness, media, attachment) = try await make(mime: "image/jpeg")
    let original = try media.fileURL(attachment.relativePath)
    let bytes = try Data(contentsOf: original)
    let entered = expectation(description: "Поставщик начал читать оригинал")
    let cancelled = expectation(description: "Поставщик получил отмену")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal(); media.close() }
    media.remoteFile = { requested, preview, token in
      XCTAssertEqual(requested.id, attachment.id)
      XCTAssertFalse(preview)
      token.onCancel { cancelled.fulfill() }
      entered.fulfill()
      guard release.wait(timeout: .now() + 5) == .success else { throw MediaError.io }
      return (original, attachment.mime)
    }

    let read = Task { try await media.ensureOriginal(attachment) }
    await fulfillment(of: [entered], timeout: 3)
    read.cancel()
    await fulfillment(of: [cancelled], timeout: 3)
    release.signal()
    switch await read.result {
    case .success:
      XCTFail("Опоздавший оригинал нельзя выдать закрытому экрану")
    case .failure(let error):
      XCTAssertEqual(error as? MediaError, .cancelled)
    }

    media.remoteFile = nil
    let reloaded = try await media.ensureOriginal(attachment)
    XCTAssertEqual(reloaded, original)
    XCTAssertEqual(try Data(contentsOf: reloaded), bytes)
    try await harness.close()
  }

  // Увеличиваем фото и запрашиваем новую раскладку. Исходный размер остаётся прежним, видимая
  // рамка увеличена, а края полноэкранного изображения не скругляются.
  func testPhotoZoomRelayoutKeepsBaseGeometry() async throws {
    let (h, media, a) = try await make(mime: "image/jpeg")
    let description = String(repeating: "Подпись сохраняется при увеличении фотографии. ", count: 20)
    let viewer = PhotoViewerController(attachment: a, media: media, caption: description)
    viewer.loadViewIfNeeded()
    viewer.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    viewer.viewDidLayoutSubviews()
    let scroll = try XCTUnwrap(viewer.view.subviews.compactMap { $0 as? UIScrollView }.first)
    let content = try XCTUnwrap(scroll.delegate?.viewForZooming?(in: scroll)),
      base = content.bounds.size
    scroll.setZoomScale(2, animated: false)
    viewer.viewDidLayoutSubviews()
    XCTAssertEqual(
      content.bounds.width, base.width, accuracy: 0.1,
      "Relayout during zoom must preserve the base image dimensions")
    XCTAssertEqual(content.frame.width, base.width * 2, accuracy: 0.5)
    XCTAssertEqual(
      content.layer.sublayers?.first?.cornerRadius, 0,
      "An original photo has no rounded thumbnail clipping")
    let caption = try XCTUnwrap(viewer.view.subviews.compactMap { $0 as? UITextView }.first {
      $0.accessibilityIdentifier == "viewer.caption"
    })
    XCTAssertEqual(caption.text, description)
    XCTAssertTrue(caption.isSelectable)
    XCTAssertGreaterThan(caption.bounds.height, 0)
    XCTAssertLessThanOrEqual(caption.bounds.height, 180)
    XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)

    // После поворота окна в центре остаётся та же точка фотографии.
    scroll.setZoomScale(3, animated: false)
    scroll.contentOffset = CGPoint(
      x: 0.58 * scroll.contentSize.width - scroll.bounds.width / 2,
      y: 0.52 * scroll.contentSize.height - scroll.bounds.height / 2)
    viewer.view.frame.size = CGSize(width: 844, height: 390)
    viewer.viewDidLayoutSubviews()
    XCTAssertEqual(scroll.zoomScale, 3, accuracy: 0.01)
    XCTAssertEqual(
      (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width, 0.58,
      accuracy: 0.01)
    XCTAssertEqual(
      (scroll.contentOffset.y + scroll.bounds.height / 2) / scroll.contentSize.height, 0.52,
      accuracy: 0.01)
    XCTAssertEqual(caption.text, description)
    viewer.beginAppearanceTransition(false, animated: false)
    viewer.endAppearanceTransition()
    media.close()
    try await h.close()
  }
  func testChatAccessibilityCanCancelAndRetryTheVisibleMediaDownload() async throws {
    let (h, media, image) = try await make(mime: "image/gif")
    let original = try media.fileURL(image.relativePath)
    let draft = AttachmentDraft(
      id: image.id, relativePath: image.relativePath, mime: image.mime, byteSize: image.byteSize,
      rawWidth: image.rawWidth, rawHeight: image.rawHeight, orientation: image.orientation,
      thumbnailKey: image.thumbnailKey)
    let added = try await h.repo.send(
      SendCommand(operationID: UUID().uuidString, chatID: 2, kind: .gif, attachments: [draft]))
    let row = try XCTUnwrap(added.inserted.first)
    try await h.store.perform { db in
      try db.execute(
        "UPDATE attachments SET relativePath=? WHERE id=?",
        [.text("remote/0123456789abcdef0123456789abcdef.gif"), .text(image.id)])
    }
    let attempts = Counter()
    let resume = DispatchSemaphore(value: 0)
    let cancelled = expectation(description: "Отмена дошла до передачи видимого изображения")
    media.remoteFile = { claimed, _, token in
      XCTAssertEqual(claimed.id, image.id)
      if attempts.increment() == 1 {
        token.onCancel { resume.signal() }
        token.reportProgress(0.32)
        guard resume.wait(timeout: .now() + 10) == .success, token.isCancelled else {
          throw MediaError.unavailable
        }
        cancelled.fulfill()
        throw MediaError.cancelled
      }
      return (original, image.mime)
    }

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    let host = ChatScrollHost()
    host.frame = CGRect(x: 0, y: 80, width: 390, height: 600)
    parent.view.addSubview(host)
    host.configureMedia(media)
    defer {
      resume.signal()
      host.close()
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(chatID: 2, repository: h.repo, anchor: nil)

    func action() -> UIAccessibilityElement? {
      host.subviews.flatMap { $0.accessibilityElements ?? [] }
        .compactMap { $0 as? UIAccessibilityElement }
        .first { $0.accessibilityIdentifier == "media.load.\(row.id)" }
    }
    let downloading = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      action()?.accessibilityLabel == "Отменить загрузку"
    }, object: nil)
    await fulfillment(of: [downloading], timeout: 8)
    XCTAssertTrue(try XCTUnwrap(action()).accessibilityActivate())
    await fulfillment(of: [cancelled], timeout: 8)

    let retry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      action()?.accessibilityLabel == "Повторить загрузку"
    }, object: nil)
    await fulfillment(of: [retry], timeout: 6)
    XCTAssertTrue(try XCTUnwrap(action()).accessibilityActivate())
    let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let preview = host.scene.preview(row.id)
      defer { preview?.close() }
      return action() == nil && preview?.image != nil
    }, object: nil)
    await fulfillment(of: [shown], timeout: 8)
    XCTAssertEqual(attempts.value, 2)
    XCTAssertEqual(try Data(contentsOf: original).count, Int(image.byteSize))
    try await h.close()
  }

  // Открываем фото с маленьким кадром и задерживаем чтение оригинала. Проверяем, что отмена
  // доступна, прекращает сам запрос и оставляет уже показанное изображение.
  func testPhotoViewerCancelsOriginalDownloadAndKeepsPreview() async throws {
    let (h, media, original) = try await make(mime: "image/jpeg")
    defer { media.close() }
    let url = try media.fileURL(original.relativePath), gate = DispatchSemaphore(value: 0)
    let entered = expectation(description: "photo original requested"),
      cancelled = expectation(description: "original I/O cancelled")
    let attachment = Attachment(
      id: original.id, relativePath: "remote/0123456789abcdef0123456789abcdef.jpg",
      mime: original.mime, byteSize: original.byteSize, rawWidth: original.rawWidth,
      rawHeight: original.rawHeight, orientation: original.orientation, durationMs: nil,
      thumbnailKey: original.thumbnailKey)
    media.remoteFile = { _, preview, token in
      if preview { return (url, "image/jpeg") }
      entered.fulfill()
      gate.wait()
      if token.isCancelled {
        cancelled.fulfill()
        throw MediaError.cancelled
      }
      return (url, "image/jpeg")
    }
    let viewer = PhotoViewerController(attachment: attachment, media: media)
    viewer.loadViewIfNeeded()
    viewer.view.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    viewer.viewDidLayoutSubviews()
    viewer.beginAppearanceTransition(true, animated: false)
    viewer.endAppearanceTransition()
    await fulfillment(of: [entered], timeout: 3)
    let cancel = viewer.view.subviews.compactMap { $0 as? UIControl }.first {
      $0.accessibilityIdentifier == "media.cancel" && !$0.isHidden
    }
    XCTAssertNotNil(cancel, "Full-screen photo loading must expose a cancellation control")
    cancel?.sendActions(for: .touchUpInside)
    gate.signal()
    await fulfillment(of: [cancelled], timeout: 3)
    viewer.beginAppearanceTransition(false, animated: false)
    viewer.endAppearanceTransition()
    try await h.close()
  }

  func testResumingAFinishedVideoStartsAtTheBeginningWithTheSamePlayerItem() async throws {
    let (h, media, video) = try await make()
    let admission = MediaAdmission()
    let player = MediaCoordinator(admission: admission, media: media)
    defer {
      player.close()
      media.close()
      admission.close()
    }
    player.play(target: PlaybackTarget(attachment: video, messageID: 912, kind: .video))
    let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      player.isReady && player.durationMs > 0 && !player.isPlaying
        && player.positionMs >= player.durationMs - 50
    }, object: nil)
    await fulfillment(of: [ended], timeout: 10)
    let item = try XCTUnwrap(player.session.player.currentItem)
    let end = player.positionMs

    player.resume(immediately: true)
    let replaying = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      player.isPlaying && player.positionMs < end / 2
    }, object: nil)
    await fulfillment(of: [replaying], timeout: 6)
    XCTAssertTrue(player.session.player.currentItem === item)
    XCTAssertEqual(player.currentMessageID, 912)
    try await h.close()
  }

  func testPhotoViewerCanRetryAnOriginalAfterFailureAndThenDismiss() async throws {
    let (h, media, original) = try await make(mime: "image/jpeg")
    let url = try media.fileURL(original.relativePath)
    let attempts = Counter()
    let completeRetry = DispatchSemaphore(value: 0)
    let retryStarted = expectation(description: "Средство просмотра повторило чтение оригинала")
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    defer {
      completeRetry.signal()
      parent.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKeyAndVisible()
      media.close()
    }
    let attachment = Attachment(
      id: original.id, relativePath: "remote/0123456789abcdef0123456789abcdef.jpg",
      mime: original.mime, byteSize: original.byteSize, rawWidth: original.rawWidth,
      rawHeight: original.rawHeight, orientation: original.orientation, durationMs: nil,
      thumbnailKey: original.thumbnailKey)
    media.remoteFile = { _, preview, token in
      if !preview {
        let attempt = attempts.increment()
        if attempt == 1 { throw MediaError.unavailable }
        if attempt == 2 {
          token.reportProgress(0.4)
          retryStarted.fulfill()
          guard completeRetry.wait(timeout: .now() + 8) == .success else {
            throw MediaError.cancelled
          }
        }
      }
      return (url, "image/jpeg")
    }
    let viewer = PhotoViewerController(attachment: attachment, media: media)
    parent.present(viewer, animated: false)
    viewer.view.layoutIfNeeded()
    let controls = viewer.view.subviews.compactMap { $0 as? UIControl }
    let retry = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "media.retry" })
    let progress = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "media.cancel" })
    let close = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "photo.close" })
    let failure = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !retry.isHidden && retry.accessibilityLabel == "Не удалось загрузить. Повторить"
    }, object: nil)
    await fulfillment(of: [failure], timeout: 8)
    XCTAssertTrue(progress.isHidden)
    retry.sendActions(for: .touchUpInside)
    await fulfillment(of: [retryStarted], timeout: 8)
    let percent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      !progress.isHidden && progress.accessibilityValue == "40%"
    }, object: nil)
    await fulfillment(of: [percent], timeout: 3)
    completeRetry.signal()
    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let frame = viewer.retainedPreview() else { return false }
      defer { frame.close() }
      return !frame.isTinyPreview && progress.isHidden && retry.isHidden
    }, object: nil)
    await fulfillment(of: [loaded], timeout: 8)
    close.sendActions(for: .touchUpInside)
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in parent.presentedViewController == nil }, object: nil)
    await fulfillment(of: [closed], timeout: 8)
    XCTAssertGreaterThanOrEqual(attempts.value, 2)
    try await h.close()
  }

  // Сто раз готовим, перематываем и останавливаем видео. В каждом цикле активен один
  // проигрыватель, а после остановки нет источника и удержанной памяти.
  func testHundredPrepareSeekStopCyclesKeepOneNativeOwner() async throws {
    let (h, media, video) = try await make(), admission = MediaAdmission(),
      c = MediaCoordinator(admission: admission, media: media)
    defer {
      c.close()
      media.close()
      admission.close()
    }
    let
      sourceURL = try XCTUnwrap(
        Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
      ).appendingPathComponent("media/video-01.mp4"),
      draft = try await media.stage(sourceURL: sourceURL, mime: "video/mp4")
    let secondVideo = Attachment(
      id: draft.id, relativePath: draft.relativePath, mime: draft.mime, byteSize: draft.byteSize,
      rawWidth: draft.rawWidth, rawHeight: draft.rawHeight, orientation: draft.orientation,
      durationMs: draft.durationMs, thumbnailKey: draft.thumbnailKey)
    for n in 0..<100 {
      let target = PlaybackTarget(
        attachment: n % 3 == 0 ? secondVideo : video, messageID: Int64(1000 + n),
        kind: n % 3 == 1 ? .round : .video)
      c.play(target: target)
      if n % 7 == 0 {
        c.stop()
      } else {
        for _ in 0..<200 where !c.isReady && c.lastError == nil {
          try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(c.lastError, "Cycle \(n)")
        XCTAssertTrue(c.isReady, "Cycle \(n)")
        XCTAssertEqual(c.activePlayerCount, 1)
        let done = expectation(description: "Cycle \(n) final seek")
        c.pause()
        c.seek(ms: 1200) { ok in
          XCTAssertTrue(ok)
          done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        c.stop()
      }
      XCTAssertEqual(c.activePlayerCount, 0)
      XCTAssertNil(c.session.player.currentItem)
    }
    c.close()
    media.close()
    for _ in 0..<100 where media.bytesUsed > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(media.bytesUsed, 0)
    try await h.close()
  }

  // Привязываем фото с подписью и проверяем, что только верхние углы скруглены. Прямой нижний
  // край должен прилегать к тексту.
  func testCaptionImageUsesCompactContentMergeCorner() async throws {
    let (h, media, a) = try await make(mime: "image/jpeg"), slot = MediaImageSlot(store: media)
    slot.bind(
      a, frame: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 15, bottomSquare: true)
    XCTAssertEqual(slot.layer.cornerRadius, 15)
    XCTAssertTrue(slot.layer.maskedCorners.contains(.layerMinXMinYCorner))
    XCTAssertTrue(slot.layer.maskedCorners.contains(.layerMaxXMinYCorner))
    XCTAssertFalse(slot.layer.maskedCorners.contains(.layerMinXMaxYCorner))
    XCTAssertFalse(slot.layer.maskedCorners.contains(.layerMaxXMaxYCorner))
    slot.close()
    media.close()
    try await h.close()
  }

}

private extension VideoCoverDiskCache {
  // Берём сохранённые точки по ключу и создаём удержанную копию для проверки. Пока она жива,
  // собственную ссылку чтения уже можно отпустить.
  func readFrameForTest(_ key: VideoPlaybackKey, budget: ImageByteBudget) -> PreparedImage? {
    guard let pixels = readPixels(key, budget: budget) else { return nil }
    defer { pixels.closeOwner() }
    return pixels.frame()
  }
}
