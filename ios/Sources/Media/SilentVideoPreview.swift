import UIKit
import AVFoundation
import CoreImage

@MainActor final class SilentVideoPreview {
  let layer = AVPlayerLayer()
  private let store: MediaStore
  private let player = AVPlayer()
  private var source: MediaPlaybackSource?, task: Task<Void, Never>?, lifetime: PreviewLifetime?
  private var readyObservation: NSKeyValueObservation?, statusObservation: NSKeyValueObservation?
  private var ended: NSObjectProtocol?, invalidation: UUID?
  private var identity: String?, generation = 0
  private var playbackKey: VideoPlaybackKey?
  private var cacheGeneration = 0
  private var output: AVPlayerItemVideoOutput?
  private var videoTransform = CGAffineTransform.identity
  private var restoring = false
  private var failed = false
  private nonisolated static let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var visible = true
  private(set) var closed = false
  var onChange: (() -> Void)?
  var onPausedFrame: (() -> Void)?
  var active: Bool { !closed && !restoring && layer.player != nil && layer.isReadyForDisplay }
  var presented: Bool { active && visible }
  var isPlaying: Bool { presented && player.rate > 0 }
  func setVisible(_ value: Bool) {
    guard !closed, visible != value else { return }
    visible = value
    if value {
      if player.currentItem != nil && !restoring { player.play() }
      if active { layer.opacity = 1 }
    } else {
      if failed { close(); return }
      pauseAndRememberPlayback()
      layer.opacity = 0
    }
  }
  /// Подключает закрытие при потере действительности соответствующего медиа в хранилище.
  init(store: MediaStore) {
    self.store = store
    player.isMuted = true
    player.volume = 0
    player.automaticallyWaitsToMinimizeStalling = false
    layer.opacity = 0
    layer.masksToBounds = true
    layer.videoGravity = .resizeAspectFill
    invalidation = store.registerInvalidation { [weak self] in self?.close() }
  }
  /// Один владелец относится к одному исходнику, поэтому при замене файла закрывается для создания
  /// следующего.
  func bind(
    _ attachment: Attachment, frame: CGRect, circular: Bool, cornerRadius: CGFloat,
    bottomSquare: Bool, studioAlbum: Bool = false, playbackKey: VideoPlaybackKey? = nil,
    localOnly: Bool = false
  ) {
    guard !closed else { return }
    let radius = circular ? min(frame.width, frame.height) / 2 : cornerRadius
    let corners: CACornerMask =
      circular || !bottomSquare
      ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
      : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    let moved = layer.frame != frame
    let radiusChanged = layer.cornerRadius != radius
    let cornersChanged = layer.maskedCorners != corners
    if moved || radiusChanged || cornersChanged {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if moved { layer.frame = frame }
      if radiusChanged { layer.cornerRadius = radius }
      if cornersChanged { layer.maskedCorners = corners }
      CATransaction.commit()
    }
    if let identity {
      if identity != attachment.relativePath { close() }
      return
    }
    guard
      let lease = MediaAdmission.reservePreview(
        studioAlbum: studioAlbum, stop: { [weak self] in self?.close() })
    else { return }
    let life = PreviewLifetime(lease)
    lifetime = life
    self.playbackKey = playbackKey ?? VideoPlaybackKey(messageID: 0, attachment: attachment)
    cacheGeneration = store.videoPlayback.generation
    identity = attachment.relativePath
    generation += 1
    let ticket = generation, store = self.store
    life.begin()
    task = Task { [weak self] in
      defer { life.end() }
      do {
        let source = try await store.playbackSource(attachment, localOnly: localOnly)
        guard let self, !self.closed, self.generation == ticket, !Task.isCancelled else {
          source.close()
          return
        }
        self.source = source
        let asset = try await store.silentVideoAsset(source)
        guard !self.closed, self.generation == ticket, !Task.isCancelled else {
          source.close()
          return
        }
        self.task = nil
        self.install(source, asset: asset, ticket: ticket)
      } catch {
        guard let self, !self.closed, self.generation == ticket else { return }
        self.task = nil
        if localOnly { self.close() } else { self.failPreview() }
      }
    }
  }
  private func install(_ source: MediaPlaybackSource, asset: AVAsset, ticket: Int) {
    self.source = source
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 1
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    self.output = output
    videoTransform = (asset as? AVComposition)?.tracks.first(where: { $0.mediaType == .video })?.preferredTransform ?? .identity
    let saved = playbackKey.map { store.videoPlayback.position($0) } ?? 0
    restoring = saved > 0
    readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) {
      [weak self, weak item] output, _ in
      let ready = output.isReadyForDisplay
      DispatchQueue.main.async { [weak self, weak item] in
        guard let self, let item, !self.closed, self.generation == ticket,
          self.player.currentItem === item, ready, !self.restoring
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer.opacity = self.visible ? 1 : 0
        CATransaction.commit()
        if self.visible { self.player.play() }
        self.onChange?()
      }
    }
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard item.status == .failed else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.closed, self.generation == ticket else { return }
        self.failPreview()
      }
    }
    ended = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self, let item, !self.closed, self.generation == ticket,
          self.player.currentItem === item
        else { return }
        self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) {
          [weak self] finished in
          DispatchQueue.main.async { [weak self] in
            guard let self, finished, !self.closed, self.generation == ticket else { return }
            if self.visible { self.player.play() }
          }
        }
      }
    }
    player.replaceCurrentItem(with: item)
    if saved > 0 {
      player.seek(to: CMTime(seconds: saved, preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.closed, self.generation == ticket else { return }
          guard finished else { self.failPreview(); return }
          self.restoring = false
          self.layer.player = self.player
          if self.active {
            self.layer.opacity = self.visible ? 1 : 0
            if self.visible { self.player.play() }
          }
          self.onChange?()
        }
      }
    } else {
      layer.player = player
      if visible { player.play() }
    }
  }
  // При открытии просмотра передаём видимый кадр, а не заставку под проигрывателем.
  func snapshotFrame() -> PreparedImage? {
    rememberPlayback(at: player.currentTime(), immediate: true)
    return playbackKey.flatMap { store.videoPlayback.frame($0) }
  }
  private func pauseAndRememberPlayback() {
    // После паузы системный проигрыватель может вернуть время соседнего ключевого кадра.
    let time = player.currentTime()
    player.pause()
    rememberPlayback(at: time)
  }
  private func rememberPlayback(at time: CMTime, immediate: Bool = false) {
    guard let playbackKey, !restoring, player.currentItem != nil else { return }
    store.videoPlayback.rememberPosition(time.seconds, key: playbackKey, generation: cacheGeneration)
    guard active, let buffer = output?.copyPixelBuffer(
      forItemTime: time, itemTimeForDisplay: nil) else { return }
    let raw = CIImage(cvPixelBuffer: buffer).transformed(by: videoTransform)
    let image = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
    let width = Int(image.extent.width), height = Int(image.extent.height)
    let render: (Int, Int) -> CGImage? = { w, h in
      let scaled = image.transformed(by: CGAffineTransform(
        scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
      return Self.imageContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h),
        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
    }
    if immediate {
      store.videoPlayback.rememberFrame(key: playbackKey, generation: cacheGeneration,
        width: width, height: height, render: render)
    } else {
      let sourceBytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
      store.videoPlayback.enqueueFrame(key: playbackKey, generation: cacheGeneration,
        width: width, height: height, sourceBytes: sourceBytes,
        published: { [weak self] in
          guard let self, !self.closed, !self.visible, self.playbackKey == playbackKey else { return }
          self.onPausedFrame?()
        }, render: render)
    }
  }
  private func failPreview() {
    failed = true
    generation += 1
    retireNative()
    // Пока строка видна, ошибка остаётся на месте. Новый запрос начнётся после
    // ухода и возврата, а обновление экрана не создаст непрерывных повторов.
    if visible { onChange?() } else { close() }
  }
  private func retireNative() {
    task?.cancel()
    task = nil
    readyObservation?.invalidate()
    readyObservation = nil
    statusObservation?.invalidate()
    statusObservation = nil
    if let ended { NotificationCenter.default.removeObserver(ended) }
    ended = nil
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    layer.player = nil
    player.replaceCurrentItem(with: nil)
    output = nil
    restoring = false
    layer.opacity = 0
    source?.close()
    source = nil
    lifetime?.retire()
    lifetime = nil
  }
  func close() {
    guard !closed else { return }
    // У невидимого ролика позиция уже снята при паузе. При освобождении сохраняем
    // это время, чтобы позднее состояние проигрывателя его не затёрло.
    if visible {
      pauseAndRememberPlayback()
    }
    closed = true
    generation += 1
    onChange?()
    retireNative()
    layer.removeFromSuperlayer()
    if let invalidation { store.unregisterInvalidation(invalidation) }
    invalidation = nil
  }
}
