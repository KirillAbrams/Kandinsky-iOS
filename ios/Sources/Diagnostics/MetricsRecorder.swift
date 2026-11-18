// Собирает замеры времени и движения ленты на айфоне с ограничением памяти. Пишет время вызовов и
// положение слоёв, а число кадров на экране подтверждают отдельные замеры.

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
  // Задаёт число сохраняемых значений в каждой серии. Минимум одно место защищает запись от
  // попытки обновить пустой буфер.
  init(capacity: Int = 8192) { self.capacity = max(1, capacity) }
  // Берёт отметку часов, которые идут независимо от настроек даты. Перевод времени телефона не
  // исказит длину операции.
  func begin() -> Double { CACurrentMediaTime() }
  // Вычитает начальное время и записывает длительность под заданным именем. Все такие интервалы
  // попадают в отчёт в миллисекундах.
  func end(_ name: String, _ token: Double) {
    record(name, milliseconds: (CACurrentMediaTime() - token) * 1000)
  }
  // Принимает только конечную неотрицательную длительность и ограничивает число серий. Последние
  // значения заменяют старые, а общий счёт и максимум сохраняются.
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
  // Обновляет наибольшее значение показателя и ограничивает число имён. Диагностика не
  // накапливает бесконечное число счётчиков.
  func peak(_ name: String, _ value: Int) {
    guard peaks[name] != nil || peaks.count < 12 else { return }
    peaks[name] = max(peaks[name] ?? 0, value)
  }
  // Сортирует сохранённые замеры для середины и верхних долей, а счёт и максимум берёт за всё
  // время. Так видно, сколько замеров ещё осталось в памяти.
  func statistics(_ name: String) -> NumericStatistics? {
    guard let series = samples[name], !series.values.isEmpty else { return nil }
    let sorted = series.values.sorted()
    // Выбирает позицию заданной доли в отсортированном ряду с округлением вверх. Крайний замер
    // при малом числе значений тоже участвует.
    func percentile(_ fraction: Double) -> Double {
      sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    return NumericStatistics(
      count: series.count, retained: sorted.count, p50: percentile(0.5), p95: percentile(0.95),
      p99: percentile(0.99),
      maximum: series.maximum)
  }
  // Возвращает последние замеры в порядке записи, учитывая место замены старых значений. В отчёте
  // конец ряда не поменяется местами с началом.
  func rawSamples() -> [String: [Double]] {
    samples.mapValues { series in
      series.values.count < capacity
        ? series.values
        : Array(series.values.dropFirst(series.next)) + Array(series.values.prefix(series.next))
    }
  }
  // Собирает сводки всех записанных длительностей. Пустому имени не создаётся выдуманный замер.
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
  // Готовит отчёт с замерами сцены и частотой, доступной экрану. Пока файл пишется, хранит только
  // последний ожидающий отчёт, чтобы очередь не росла.
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
  // Передаёт очередной отчёт на фоновую запись и заменяет файл целиком. После завершения снова
  // проверяет ожидание, чтобы свежий отчёт не потерялся.
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
  // Передаёт сигнал экрана наблюдателю по слабой ссылке. Системный таймер не удерживает ушедший
  // объект прокрутки.
  @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}
@MainActor final class ScrollFrameProbe {
  private var link: CADisplayLink?
  private let proxy = FrameTick()
  private var previous: Double?
  // Создаёт наблюдение за вызовами главного потока только при включённом замере. Просит рабочую
  // частоту экрана, но сами вызовы ещё не доказывают показ кадра.
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
  // Замеряет время от предыдущего вызова на главном потоке и сохраняет новую отметку. Первый
  // вызов задаёт начало, потому что интервала ещё нет.
  func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    if let previous {
      MetricsRuntime.recorder.record(
        "scroll_main_callback_ms", milliseconds: (now - previous) * 1000)
    }
    previous = now
  }
  // Останавливает наблюдение, очищает предыдущую отметку и просит записать отчёт. Повторный
  // запуск не сравнит первый сигнал с прошлым окном.
  func stop() {
    link?.invalidate()
    link = nil
    previous = nil
    MetricsRuntime.export()
  }
  // Выключает таймер при освобождении наблюдателя, чтобы он не продолжал вызывать пустой
  // обработчик.
  deinit { link?.invalidate() }
}

@MainActor private final class MotionTick: NSObject {
  weak var owner: ScrollMotionProbe?
  // Просит наблюдатель записать одно положение ленты. Слабый владелец позволяет завершить
  // наблюдение после ухода экрана.
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
  // Подключает измерение движения или только сверку времени при запросе диагностики. В режиме
  // часов не создаёт регулярный сбор положений.
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
  // Считает проходы отрисовки, пока отчёт открыт, и отмечает время. По счётчику можно увидеть
  // работу раскладки отдельно от смены положения ленты.
  func noteRender() {
    guard !closed, output != nil else { return }
    renderCount += 1
    noteClock()
  }
  // Записывает общую метку отчёта и системного журнала не чаще раза в секунду, кроме явного
  // запроса. По ней можно совместить два источника по времени.
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
  // Снимком записывает положение, высоту, жест и движение, а на регулярном пробном вызове ещё и
  // видимое положение слоя. При неверных числах или заполнении считает потерянные замеры без
  // роста памяти.
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
  // Добавляет последнюю отметку, останавливает таймер и освобождает ссылку на прокрутку. Отчёт
  // сохраняется фоном, чтобы закрытие чата не ждало диска.
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
  // Выключает ещё запущенный таймер при уходе наблюдателя. Даже без отдельного закрытия
  // регулярные вызовы прекратятся.
  deinit { link?.invalidate() }
}
