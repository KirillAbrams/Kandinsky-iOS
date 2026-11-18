import AVFoundation
import CoreImage

@MainActor final class PlayerSession {
  let player = AVQueuePlayer()
  private var status: NSKeyValueObservation?, buffering: NSKeyValueObservation?,
    itemChange: NSKeyValueObservation?, loopStatus: NSKeyValueObservation?, clock: Any?
  private var looper: AVPlayerLooper?
  private var generation = 0, seekGeneration = 0
  private var source: MediaPlaybackSource?
  private var frameOutput: AVPlayerItemVideoOutput?
  private weak var frameItem: AVPlayerItem?
  private static let frameContext = CIContext(options: [.cacheIntermediates: false])
  var onChange: (() -> Void)?
  var onFailure: ((Error) -> Void)?
  var ready: Bool { player.currentItem?.status == .readyToPlay }
  var durationMs: Int64 {
    let value = player.currentItem?.duration.seconds ?? 0
    return value.isFinite ? Int64(max(0, value) * 1000) : 0
  }
  var positionMs: Int64 {
    let value = player.currentTime().seconds
    return value.isFinite ? Int64(max(0, value) * 1000) : 0
  }
  init() { player.isMuted = true }
  /// Отслеживает готовность, ошибки и положение с проверкой поколения, чтобы поздние события не меняли
  /// другой источник.
  func replace(source: MediaPlaybackSource, loop: Bool = false) {
    stop()
    self.source = source
    let ticket = generation
    let item = AVPlayerItem(asset: source.asset)
    item.preferredForwardBufferDuration = 3
    // Обычное содержимое сохраняем в конце очереди, чтобы оставались доступны перемотка и повтор.
    player.actionAtItemEnd = loop ? .advance : .pause
    itemChange = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == ticket else { return }
        self.observeCurrentItem(ticket: ticket)
      }
    }
    buffering = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == ticket else { return }
        self.onChange?()
      }
    }
    if loop {
      // Управление медиа читает длительность источника асинхронно до выдачи разрешения
      let looper = AVPlayerLooper(player: player, templateItem: item)
      self.looper = looper
      loopStatus = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == ticket else { return }
          if looper.status == .failed { self.onFailure?(looper.error ?? MediaError.corrupt) }
        }
      }
    } else {
      player.replaceCurrentItem(with: item)
    }
    clock = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4), queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.onChange?() } }
  }
  private func observeCurrentItem(ticket: Int) {
    status?.invalidate()
    status = nil
    guard let item = player.currentItem else {
      onChange?()
      return
    }
    if frameItem !== item {
      if let old = frameItem, let frameOutput { old.remove(frameOutput) }
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
      item.add(output)
      frameOutput = output
      frameItem = item
    }
    status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == ticket, self.player.currentItem === item else { return }
        if item.status == .failed { self.onFailure?(item.error ?? MediaError.corrupt) }
        self.onChange?()
      }
    }
  }
  func seek(ms: Int64, completion: @escaping (Bool) -> Void) {
    seekGeneration += 1
    let seekTicket = seekGeneration
    let ticket = generation
    player.currentItem?.cancelPendingSeeks()
    player.seek(
      to: CMTime(value: max(0, ms), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero
    ) { [weak self] done in
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          completion(false)
          return
        }
        completion(done && self.generation == ticket && self.seekGeneration == seekTicket)
        self.onChange?()
      }
    }
  }
  func rememberFrame(in cache: VideoPlaybackCache, key: VideoPlaybackKey, generation: Int) {
    guard ready, let item = player.currentItem,
      let buffer = frameOutput?.copyPixelBuffer(
        forItemTime: player.currentTime(), itemTimeForDisplay: nil)
    else { return }
    let transform = item.asset.tracks(withMediaType: .video).first?.preferredTransform ?? .identity
    let oriented = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
    let image = oriented.transformed(
      by: CGAffineTransform(
        translationX: -oriented.extent.minX, y: -oriented.extent.minY))
    cache.rememberFrame(
      key: key, generation: generation,
      width: Int(image.extent.width), height: Int(image.extent.height)
    ) { w, h in
      let scaled = image.transformed(
        by: CGAffineTransform(
          scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
      return Self.frameContext.createCGImage(
        scaled,
        from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, deferred: false)
    }
  }
  func stop() {
    generation += 1
    seekGeneration += 1
    player.currentItem?.cancelPendingSeeks()
    status?.invalidate()
    status = nil
    buffering?.invalidate()
    buffering = nil
    itemChange?.invalidate()
    itemChange = nil
    loopStatus?.invalidate()
    loopStatus = nil
    if let clock { player.removeTimeObserver(clock) }
    clock = nil
    player.pause()
    if let frameOutput, let frameItem { frameItem.remove(frameOutput) }
    frameOutput = nil
    frameItem = nil
    looper?.disableLooping()
    looper = nil
    player.removeAllItems()
    source?.close()
    source = nil
  }
}
