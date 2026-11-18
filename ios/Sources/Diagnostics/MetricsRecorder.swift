import Foundation
import QuartzCore
import UIKit
import os
struct NumericStatistics: Codable {
  let count: Int, retained: Int
  let p50: Double, p95: Double, p99: Double, maximum: Double
}
@MainActor final class MetricsRecorder {
  private struct Samples {
    var values: [Double] = []
    var next = 0
    var count = 0
    var maximum = 0.0
  }
  private var samples: [String: Samples] = [:]
  private(set) var peaks: [String: Int] = [:]
  private let capacity: Int
  init(capacity: Int = 8192) { self.capacity = max(1, capacity) }
  /// Монотонные часы продолжают отсчёт, даже если пользователь поменял время на телефоне.
  func begin() -> Double { CACurrentMediaTime() }
  func end(_ name: String, _ token: Double) {
    record(name, milliseconds: (CACurrentMediaTime() - token) * 1000)
  }
  /// Храним только последние замеры. Общее число и максимум считаем с начала работы.
  func record(_ name: String, milliseconds: Double) {
    guard milliseconds.isFinite, milliseconds >= 0, samples[name] != nil || samples.count < 8 else {
      return
    }
    var series = samples[name] ?? Samples()
    series.count += 1
    series.maximum = max(series.maximum, milliseconds)
    if series.values.count < capacity {
      series.values.append(milliseconds)
    } else {
      series.values[series.next] = milliseconds
      series.next = (series.next + 1) % capacity
    }
    samples[name] = series
  }
  /// Ограничиваем число имён показателей, чтобы диагностика не расходовала всё больше памяти.
  func peak(_ name: String, _ value: Int) {
    guard peaks[name] != nil || peaks.count < 12 else { return }
    peaks[name] = max(peaks[name] ?? 0, value)
  }
  /// Медиану и процентили считаем по последним замерам, максимум берём за всё время.
  func statistics(_ name: String) -> NumericStatistics? {
    guard let series = samples[name], !series.values.isEmpty else { return nil }
    let sorted = series.values.sorted()
    func percentile(_ fraction: Double) -> Double {
      sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    return NumericStatistics(
      count: series.count, retained: sorted.count, p50: percentile(0.5), p95: percentile(0.95),
      p99: percentile(0.99),
      maximum: series.maximum)
  }
  func rawSamples() -> [String: [Double]] {
    samples.mapValues { series in
      series.values.count < capacity
        ? series.values
        : Array(series.values.dropFirst(series.next)) + Array(series.values.prefix(series.next))
    }
  }
  func snapshot() -> [String: NumericStatistics] {
    samples.keys.reduce(into: [:]) { $0[$1] = statistics($1) }
  }
}
@MainActor enum MetricsRuntime {
  static var enabled = false
  static let recorder = MetricsRecorder()
  static var output: URL?
  private static let writer = DispatchQueue(label: "Kandinsky.NumericMetrics")
  private static var writing = false
  private static var pending: Data?
  /// Пока файл записывается, оставляем только самый свежий отчёт.
  static func export() {
    guard enabled, let output else { return }
    struct Report: Codable {
      let scope: String
      let statistics: [String: NumericStatistics]
      let rawSamples: [String: [Double]]
      let displayMaximumFPS: Int
      let peaks: [String: Int]
    }
    guard
      let data = try? JSONEncoder().encode(
        Report(
          scope: "Simulator main callback cadence and scene CPU; not physical GPU presentation",
          statistics: recorder.snapshot(), rawSamples: recorder.rawSamples(),
          displayMaximumFPS: UIScreen.main.maximumFramesPerSecond, peaks: recorder.peaks))
    else { return }
    pending = data
    guard !writing else { return }
    writeNext(output)
  }
  private static func writeNext(_ url: URL) {
    guard let data = pending else {
      writing = false
      return
    }
    pending = nil
    writing = true
    writer.async {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
      DispatchQueue.main.async { writeNext(url) }
    }
  }
}
@MainActor private final class FrameTick: NSObject {
  weak var owner: ScrollFrameProbe?
  /// Таймер удерживает своего получателя. Слабая ссылка позволяет освободить наблюдатель прокрутки.
  @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}
@MainActor final class ScrollFrameProbe {
  private var link: CADisplayLink?
  private let proxy = FrameTick()
  private var previous: Double?
  /// Замер показывает интервал между вызовами главного потока. По нему нельзя узнать, сколько кадров увидел
  /// человек.
  func start() {
    guard MetricsRuntime.enabled, link == nil else { return }
    previous = nil
    proxy.owner = self
    let value = CADisplayLink(target: proxy, selector: #selector(FrameTick.tick(_:)))
    let maximum = Float(UIScreen.main.maximumFramesPerSecond)
    value.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximum), maximum: maximum, preferred: maximum)
    link = value
    value.add(to: .main, forMode: .common)
  }
  func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    if let previous {
      MetricsRuntime.recorder.record(
        "scroll_main_callback_ms", milliseconds: (now - previous) * 1000)
    }
    previous = now
  }
  func stop() {
    link?.invalidate()
    link = nil
    previous = nil
    MetricsRuntime.export()
  }
  deinit { link?.invalidate() }
}

@MainActor private final class MotionTick: NSObject {
  weak var owner: ScrollMotionProbe?
  @objc func tick(_ link: CADisplayLink) { owner?.record(.sample) }
}

@MainActor final class ScrollMotionProbe {
  enum Event: String, Codable, Sendable {
    case open, sample, willBeginDragging, didEndDragging, didEndDecelerating, geometryWillChange,
      geometryDidChange, close
  }
  private struct Sample: Codable, Sendable {
    let epoch: Double, event: Event, offsetY: Double, contentHeight: Double
    let presentedOffsetY: Double?, renderCount: Int
    let tracking: Bool, dragging: Bool, decelerating: Bool, compositorDriven: Bool
    let willDecelerate: Bool?,
      preservingMotion: Bool?
  }
  private struct Report: Codable, Sendable {
    let scope: String, startedEpoch: Double, endedEpoch: Double, capacity: Int, dropped: Int,
      samples: [Sample]
    let clockID: String, startedClock: Double, clockMarkerRequests: Int, renderCount: Int,
      recordsMotion: Bool
  }
  private static let writer = DispatchQueue(label: "Kandinsky.ScrollMotionExport", qos: .utility)
  private static let signposter = OSSignposter(
    subsystem: "dev.kirill.kandinsky.chat", category: "KandinskyMotion")
  private weak var scroll: UIScrollView?
  private let proxy = MotionTick()
  private var link: CADisplayLink?
  private var output: URL?
  private var samples: [Sample] = []
  private let capacity = 16_384
  private var dropped = 0, closed = false
  private var startedEpoch = 0.0, startedClock = 0.0
  private var clockID = "", nextClockMarker = 0.0
  private var clockMarkerRequests = 0, renderCount = 0
  private var recordsMotion = false
  func start(_ scroll: UIScrollView) {
    let requested = getenv("KANDINSKY_SCROLL_MOTION").map { String(cString: $0) == "1" } ?? false
    let clockOnly = getenv("KANDINSKY_PERF_CLOCK").map { String(cString: $0) == "1" } ?? false
    guard MetricsRuntime.enabled || requested || clockOnly, let numeric = MetricsRuntime.output,
      !closed, output == nil
    else { return }
    self.scroll = scroll
    output = numeric.deletingLastPathComponent().appendingPathComponent(
      numeric.deletingPathExtension().lastPathComponent + "-motion.json")
    startedEpoch = Date().timeIntervalSince1970
    startedClock = CACurrentMediaTime()
    clockID = UUID().uuidString
    recordsMotion = MetricsRuntime.enabled || requested
    noteClock(force: true)
    guard recordsMotion else { return }
    proxy.owner = self
    record(.open)
    let link = CADisplayLink(target: proxy, selector: #selector(MotionTick.tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }
  func noteRender() {
    guard !closed, output != nil else { return }
    renderCount += 1
    noteClock()
  }
  /// Метка связывает время в отчёте прокрутки со временем в системном журнале.
  private func noteClock(force: Bool = false) {
    guard !closed, output != nil else { return }
    let now = CACurrentMediaTime()
    guard force || now >= nextClockMarker else { return }
    nextClockMarker = now + 1
    let epoch = startedEpoch + now - startedClock, wall = Date().timeIntervalSince1970, id = clockID
    clockMarkerRequests += 1
    Self.signposter.emitEvent(
      "KandinskyMotionClock",
      """
      id=\(id,privacy:.public) epoch=\(epoch,format:.fixed(precision:9),privacy:.public) \
      wall=\(wall,format:.fixed(precision:9),privacy:.public)
      """
    )
  }
  func record(_ event: Event, willDecelerate: Bool? = nil, preservingMotion: Bool? = nil) {
    guard !closed, output != nil, recordsMotion, let scroll else { return }
    noteClock()
    let host = scroll as? ChatScrollHost
    let epoch = startedEpoch + CACurrentMediaTime() - startedClock
    let y = Double(host?.viewportOffsetY ?? scroll.contentOffset.y)
    let height = Double(scroll.contentSize.height)
    guard samples.count < capacity, epoch.isFinite, y.isFinite, height.isFinite else {
      dropped += 1
      return
    }
    let presented: Double?
    if event != .sample {
      presented = nil
    } else if let host {
      presented = host.presentedViewportOffsetY.map { Double($0) }
    } else {
      presented = scroll.layer.presentation().map { Double($0.bounds.origin.y) }
    }
    samples.append(
      Sample(
        epoch: epoch, event: event, offsetY: y, contentHeight: height,
        presentedOffsetY: presented.flatMap { $0.isFinite ? $0 : nil }, renderCount: renderCount,
        tracking: scroll.isTracking, dragging: scroll.isDragging,
        decelerating: scroll.isDecelerating || host?.compositorFlight != nil,
        compositorDriven: host?.compositorFlight != nil,
        willDecelerate: willDecelerate,
        preservingMotion: preservingMotion))
  }
  func close() {
    guard !closed else { return }
    noteClock(force: true)
    record(.close)
    closed = true
    link?.invalidate()
    link = nil
    scroll = nil
    guard let output else { return }
    let report = Report(
      scope:
        "Sampled UIScrollView model/CA presentation and scene passes; not GPU presentation or FPS",
      startedEpoch: startedEpoch, endedEpoch: Date().timeIntervalSince1970, capacity: capacity,
      dropped: dropped, samples: samples, clockID: clockID, startedClock: startedClock,
      clockMarkerRequests: clockMarkerRequests, renderCount: renderCount,
      recordsMotion: recordsMotion)
    samples.removeAll()
    self.output = nil
    Self.writer.async {
      do {
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: output, options: .atomic)
      } catch { NSLog("Kandinsky motion diagnostic export failed: %@", String(describing: error)) }
    }
  }
  deinit { link?.invalidate() }
}
