// Наблюдаем готовность настоящих сообщений при движении видимой области. Проверка отдельно
// считает загруженные строки, подготовленный текст и уже нарисованные слои.

import XCTest
import UIKit
@testable import Kandinsky

@MainActor final class VisibleContentDiagnosticsTests: XCTestCase {
  // Ищем сохранённое поле объекта по имени и читаем его напрямую или из обёртки. Так диагностика
  // использует внутренние счётчики без новых входов в обычном коде.
  private func field<T>(_ value: Any, _ name: String, as type: T.Type) -> T? {
    let item = Mirror(reflecting: value).children.first {
      $0.label == name || $0.label == "$__lazy_storage_$_" + name
    }?.value
    if let direct = item as? T { return direct }
    return item.flatMap { Mirror(reflecting: $0).children.first?.value as? T }
  }
  // Получаем номер «Длинной истории» для проверочного аккаунта и загружаем несколько страниц в
  // отдельную местную базу. Прокручиваем с разными скоростями и проверяем, что нужные строки
  // успевают появиться при ограниченном числе слоёв.
  func testActualHistoryReadinessDuringMovingViewport() async throws {
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    defer { api.close() }
    let chatID = try await StudioTestServer.chat("Длинная история", api: api)
    let harness = try await RepositoryHarness.open()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let store = harness.store, repo = harness.repo
    let historyStore = NetworkStore(userID: profile.userId)
    try await store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT OR IGNORE INTO chats(id,title) VALUES(?,?)",
        [.integer(chatID), .text("Длинная история")])
    }
    var before: Int64?
    for _ in 0..<8 {
      let cursor = before.map { "&before=\($0)" } ?? ""
      let data = try await api.json("/v1/chats/\(chatID)/history?limit=128" + cursor)
      _ = try await store.perform { db in try historyStore.history(db, chat: chatID, data: data) }
      let page = try WireObject(data: data)
      if try !page.bool("hasOlder") { break }
      let numbers = try page.array("messages").map { try WireObject($0).int("seq") }
      let next = try XCTUnwrap(numbers.min())
      if let before { XCTAssertLessThan(next, before) }
      before = next
    }
    let indexRows = try await repo.index(chatID: chatID)
    XCTAssertGreaterThan(indexRows.count, 384)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let prior = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.backgroundColor = .darkGray
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 80, width: 390, height: 680)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      prior?.makeKey()
    }
    try await host.open(chatID: chatID, repository: repo, anchor: ReadingAnchor())
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let plane = try XCTUnwrap(field(host, "plane", as: UIView.self))
    let history = try XCTUnwrap(field(host, "index", as: HistoryIndex.self))
    let cache = try XCTUnwrap(field(host, "cache", as: FragmentLayoutCache.self))
    let retained = try XCTUnwrap(field(host, "scene", as: RetainedChatScene.self))
    let raster = try XCTUnwrap(field(retained, "rasterQueue", as: MediaDecodeQueue.self))
    var samples: [[String: Any]] = []
    // Записываем видимые номера и отмечаем, что уже загружено, подготовлено и нарисовано на
    // экране. Снимаем также длину очередей, чтобы отличить задержку данных от задержки рисования.
    func observe(_ phase: String, _ time: Double) {
      let viewport = host.bounds
      let ids = history.visible(
        offset: Double(viewport.minY), height: Double(viewport.height), overscan: 0
      ).map { history.rows[$0].messageID }
      let loaded = field(host, "loaded", as: [MessageID: Message].self) ?? [:]
      let prepared = field(cache, "values", as: [TextLayoutKey: PreparedText].self) ?? [:]
      let preparedIDs = Set(prepared.keys.map(\.messageID))
      let nodes = (plane.layer.sublayers ?? []).compactMap { $0 as? MessageLayer }
      let visible = nodes.filter { $0.frame.intersects(viewport) }
      let painted = visible.filter { node in
        node.contents != nil || (node.backgroundColor?.alpha ?? 0) > 0
          || node.sublayers?.contains { $0.contents != nil } == true
      }
      let presentation = painted.filter { node in
        guard let live = node.presentation() else { return false }
        return live.convert(live.bounds, to: window.layer.presentation()).intersects(host.frame)
      }
      samples.append([
        "phase": phase, "seconds": time, "offset": host.contentOffset.y,
        "height": host.contentSize.height,
        "currentIDs": ids, "loadedCurrent": ids.filter { loaded[$0] != nil }.count,
        "preparedCurrent": ids.filter { preparedIDs.contains($0) }.count,
        "bodyRequiredRows": ids.filter {
          loaded[$0].map { $0.kind == .text || $0.kind == .voice || !$0.caption.isEmpty } ?? false
        }.count,
        "loadedTotal": loaded.count, "preparedTotal": prepared.count, "layerTotal": nodes.count,
        "visibleLayers": visible.count,
        "paintedModelLayers": painted.count, "paintedPresentationLayers": presentation.count,
        "rasterRunning": raster.runningCount, "rasterPending": raster.pendingCount,
        "inFlightLayouts": field(
          host, "inFlight", as: [TextLayoutKey: TextLayoutCancellation].self)?.count ?? -1,
        "recordings": host.metrics.recordings
      ])
    }
    observe("settled", 0)
    var phase = "", phaseBegin = 0.0, lastTurn = 0.0
    let observer = try XCTUnwrap(
      CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { _, _ in
        MainActor.assumeIsolated {
          let now = CACurrentMediaTime()
          if !phase.isEmpty, now - lastTurn >= 0.008 {
            lastTurn = now
            observe("after-main-" + phase, now - phaseBegin)
          }
        }
      })
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    defer {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      CFRunLoopObserverInvalidate(observer)
    }
    let speeds =
      ProcessInfo.processInfo.environment["KANDINSKY_CONTENT_SPEEDS57"]?.split(separator: ",")
      .compactMap { Double($0) } ?? [3000, 6000, 12000]
    for speed in speeds {
      let begin = CACurrentMediaTime()
      var previous = begin
      phase = "speed-\(Int(speed))"
      phaseBegin = begin
      while CACurrentMediaTime() - begin < 3 {
        try await Task.sleep(nanoseconds: 16_666_667)
        let now = CACurrentMediaTime(), delta = min(0.1, now - previous)
        previous = now
        host.setContentOffset(
          CGPoint(x: 0, y: max(0, host.contentOffset.y - CGFloat(delta * speed))), animated: false)
        observe("speed-\(Int(speed))", now - begin)
      }
    }
    phase = ""
    try await Task.sleep(nanoseconds: 500_000_000)
    observe("settled-end", 0)
    let data = try JSONSerialization.data(
      withJSONObject: [
        "diagnosticOnly": true, "chatID": chatID, "messages": indexRows.count,
        "mediaNetworkConfigured": false, "samples": samples
      ], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "actual-history-readiness57"
    attachment.lifetime = .keepAlways
    add(attachment)
    for phase in ["settled"] + speeds.map { "speed-\(Int($0))" } + ["settled-end"] {
      let phaseSamples = samples.filter { $0["phase"] as? String == phase }
      let empty = phaseSamples.filter { ($0["paintedModelLayers"] as? Int) == 0 }
      print(
        """
        KANDINSKY_READINESS57 phase=\(phase) samples=\(phaseSamples.count) noPaintedModel=\(empty.count) \
        examples=\(empty.prefix(2))
        """
      )
    }
    XCTAssertLessThanOrEqual(samples.compactMap { $0["loadedTotal"] as? Int }.max() ?? 0, 384)
    XCTAssertLessThanOrEqual(samples.compactMap { $0["preparedTotal"] as? Int }.max() ?? 0, 256)
    XCTAssertLessThanOrEqual(samples.compactMap { $0["layerTotal"] as? Int }.max() ?? 0, 128)
    if ProcessInfo.processInfo.environment["KANDINSKY_REQUIRE_VISIBLE57"] == "1" {
      let required = samples.filter {
        ($0["phase"] as? String)?.hasPrefix("after-main-") == true
          && ($0["seconds"] as? Double ?? 0) > 0.5 && ($0["bodyRequiredRows"] as? Int ?? 0) > 0
      }
      let missing = required.filter { ($0["paintedModelLayers"] as? Int) == 0 }
      print("KANDINSKY_VISIBLE_CONTRACT57 required=\(required.count) missingBody=\(missing.count)")
      XCTAssertGreaterThan(
        required.count, 100, "The actual viewport must move through enough real body-bearing rows")
      XCTAssertEqual(
        missing.count, 0,
        """
        The real current viewport must not be entirely unpainted after a main turn while actual \
        text/voice/caption rows intersect it
        """
      )
    }
    host.close()
    try await store.close()
  }
}
