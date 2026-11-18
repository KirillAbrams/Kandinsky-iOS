import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class MetricsTests: XCTestCase {
  func testClockOnlyDiagnosticDoesNotSamplePositionsOrEnableOrdinaryMetrics() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      numeric = folder.appendingPathComponent("latest.json"),
      motion = folder.appendingPathComponent("latest-motion.json")
    let previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output,
      previousFlag = getenv("KANDINSKY_PERF_CLOCK").map { String(cString: $0) }
    MetricsRuntime.enabled = false
    MetricsRuntime.output = numeric
    setenv("KANDINSKY_PERF_CLOCK", "1", 1)
    let probe = ScrollMotionProbe(), scroll = UIScrollView()
    defer {
      probe.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      if let previousFlag {
        setenv("KANDINSKY_PERF_CLOCK", previousFlag, 1)
      } else {
        unsetenv("KANDINSKY_PERF_CLOCK")
      }
      try? FileManager.default.removeItem(at: folder)
    }
    probe.start(scroll)
    probe.record(.sample)
    try await Task.sleep(nanoseconds: 100_000_000)
    probe.close()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && !FileManager.default.fileExists(atPath: motion.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard FileManager.default.fileExists(atPath: motion.path) else {
      XCTFail("Clock-only mode must export the identity required to match external timing anchors")
      return
    }
    let report = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: motion)) as? [String: Any])
    XCTAssertEqual(
      (report["samples"] as? [[String: Any]])?.count, 0,
      "Clock-only measurement must not collect trajectory samples")
    XCTAssertNotNil((report["clockID"] as? String).flatMap { UUID(uuidString: $0) })
    XCTAssertGreaterThanOrEqual(report["clockMarkerRequests"] as? Int ?? 0, 2)
    XCTAssertFalse(MetricsRuntime.enabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: numeric.path))
  }
  func testNativeMotionDiagnosticExportsPositionsWithBoundedStorage() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      for n in 1...100 {
        try db.execute(
          "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
          [.integer(Int64(n)), .text("Строка \(n)."), .integer(1_793_700_000_000 + Int64(n))])
      }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      numeric = folder.appendingPathComponent("latest.json"),
      motion = folder.appendingPathComponent("latest-motion.json")
    let previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output
    MetricsRuntime.enabled = true
    MetricsRuntime.output = numeric
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousWindow = scene.windows.first { $0.isKeyWindow },
      window = UIWindow(windowScene: scene), parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      window.isHidden = true
      previousWindow?.makeKey()
      try? FileManager.default.removeItem(at: folder)
    }
    let before = Date().timeIntervalSince1970
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await Task.sleep(nanoseconds: 150_000_000)
    host.setContentOffset(CGPoint(x: 0, y: 12), animated: false)
    host.scrollViewWillBeginDragging(host)
    host.setContentOffset(CGPoint(x: 0, y: -6), animated: false)
    host.scrollViewDidEndDragging(host, willDecelerate: false)
    for _ in 0..<20_000 { host.scrollViewWillBeginDragging(host) }
    host.close()
    let after = Date().timeIntervalSince1970, deadline = Date().addingTimeInterval(3)
    while Date() < deadline && !FileManager.default.fileExists(atPath: motion.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: numeric.path),
      "The existing numeric exporter must run, proving that the diagnostic fixture is enabled")
    guard FileManager.default.fileExists(atPath: motion.path) else {
      XCTFail(
        "Native scrolling must export its actual position/state trajectory separately from callback cadence"
      )
      try await h.close()
      return
    }
    let data = try Data(contentsOf: motion),
      report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]),
      samples = try XCTUnwrap(report["samples"] as? [[String: Any]])
    print(
      "KANDINSKY_MOTION_PROBE samples=\(samples.count) dropped=\(report["dropped"] ?? -1) bytes=\(data.count)"
    )
    XCTAssertLessThanOrEqual(samples.count, 16_384)
    XCTAssertGreaterThan(try XCTUnwrap(report["dropped"] as? Int), 0)
    XCTAssertLessThanOrEqual(data.count, 4 * 1024 * 1024)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(report["startedEpoch"] as? Double), before)
    XCTAssertLessThanOrEqual(try XCTUnwrap(report["endedEpoch"] as? Double), after)
    XCTAssertTrue(samples.contains { $0["event"] as? String == "sample" })
    XCTAssertTrue(
      samples.contains {
        $0["event"] as? String == "willBeginDragging" && $0["offsetY"] as? Double == 12
      })
    XCTAssertTrue(
      samples.contains {
        $0["event"] as? String == "didEndDragging" && $0["offsetY"] as? Double == -6
          && $0["willDecelerate"] as? Bool == false
      })
    let epochs = samples.compactMap { $0["epoch"] as? Double }
    XCTAssertEqual(epochs, epochs.sorted())
    XCTAssertTrue(
      samples.allSatisfy {
        $0["tracking"] is Bool && $0["dragging"] is Bool && $0["decelerating"] is Bool
      })
    XCTAssertGreaterThan(
      report["renderCount"] as? Int ?? 0, 0,
      "The diagnostic must record actual chat render passes, separately from display callbacks")
    XCTAssertNotNil((report["clockID"] as? String).flatMap { UUID(uuidString: $0) })
    XCTAssertGreaterThan(
      report["clockMarkerRequests"] as? Int ?? 0, 0,
      "A durable clock identity needs corresponding public signpost requests for external calibration"
    )
    try await h.close()
  }
  func testMotionDiagnosticSeparatesModelFromNativePresentation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output
    MetricsRuntime.enabled = true
    MetricsRuntime.output = folder.appendingPathComponent("latest.json")
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(),
      scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 600)),
      probe = ScrollMotionProbe()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(scroll)
    scroll.contentSize = CGSize(width: 390, height: 5000)
    window.layoutIfNeeded()
    defer {
      probe.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      window.isHidden = true
      previous?.makeKey()
      try? FileManager.default.removeItem(at: folder)
    }
    probe.start(scroll)
    scroll.bounds.origin.y = 100
    let animation = CABasicAnimation(keyPath: "bounds.origin.y")
    animation.fromValue = 0
    animation.toValue = 100
    animation.duration = 1
    scroll.layer.add(animation, forKey: "native-presentation-oracle")
    CATransaction.flush()
    try await Task.sleep(nanoseconds: 150_000_000)
    let presented = try XCTUnwrap(scroll.layer.presentation()).bounds.origin.y
    XCTAssertGreaterThan(presented, 1)
    XCTAssertLessThan(
      presented, 99,
      "The fixture must expose genuinely different native model and presentation positions")
    XCTAssertEqual(scroll.contentOffset.y, 100, accuracy: 0.1)
    probe.close()
    let file = folder.appendingPathComponent("latest-motion.json"),
      deadline = Date().addingTimeInterval(3)
    while Date() < deadline && !FileManager.default.fileExists(atPath: file.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let
      report = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]),
      samples = try XCTUnwrap(report["samples"] as? [[String: Any]])
    XCTAssertTrue(
      samples.contains { sample in
        guard let model = sample["offsetY"] as? Double,
          let visual = sample["presentedOffsetY"] as? Double
        else { return false }
        return model == 100 && visual > 1 && visual < 99
      },
      "The actual CA presentation must be sampled separately; repeating model offset cannot diagnose visual timing"
    )
  }
  func testDisabledMotionDiagnosticWritesNoFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output
    MetricsRuntime.enabled = false
    MetricsRuntime.output = folder.appendingPathComponent("latest.json")
    let probe = ScrollMotionProbe(), scroll = UIScrollView()
    defer {
      probe.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      try? FileManager.default.removeItem(at: folder)
    }
    probe.start(scroll)
    probe.record(.sample)
    probe.close()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.path),
      "An ordinary launch must not create motion files or a diagnostic output directory")
  }
  func testMotionDiagnosticDoesNotRetainItsScrollView() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output
    MetricsRuntime.enabled = true
    MetricsRuntime.output = folder.appendingPathComponent("latest.json")
    let probe = ScrollMotionProbe()
    defer {
      probe.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      try? FileManager.default.removeItem(at: folder)
    }
    weak var released: UIScrollView?
    do {
      let scroll = UIScrollView()
      released = scroll
      probe.start(scroll)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(released, "The diagnostic clock must not keep a departed native scroll view alive")
    probe.close()
    let file = folder.appendingPathComponent("latest-motion.json"),
      deadline = Date().addingTimeInterval(3)
    while Date() < deadline && !FileManager.default.fileExists(atPath: file.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: file.path),
      "Closing a probe after its weak target is gone must still finish its bounded report")
  }
  func testNarrowMotionFlagDoesNotEnableOrdinaryMetrics() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
      numeric = folder.appendingPathComponent("latest.json"),
      motion = folder.appendingPathComponent("latest-motion.json")
    let previousEnabled = MetricsRuntime.enabled, previousOutput = MetricsRuntime.output,
      previousFlag = getenv("KANDINSKY_SCROLL_MOTION").map { String(cString: $0) }
    MetricsRuntime.enabled = false
    MetricsRuntime.output = numeric
    setenv("KANDINSKY_SCROLL_MOTION", "1", 1)
    let probe = ScrollMotionProbe(), scroll = UIScrollView()
    defer {
      probe.close()
      MetricsRuntime.enabled = previousEnabled
      MetricsRuntime.output = previousOutput
      if let previousFlag {
        setenv("KANDINSKY_SCROLL_MOTION", previousFlag, 1)
      } else {
        unsetenv("KANDINSKY_SCROLL_MOTION")
      }
      try? FileManager.default.removeItem(at: folder)
    }
    probe.start(scroll)
    probe.record(.sample)
    probe.close()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && !FileManager.default.fileExists(atPath: motion.path) {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: motion.path),
      "The narrow trajectory flag must work without enabling all scene metrics")
    XCTAssertFalse(MetricsRuntime.enabled)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: numeric.path),
      "No ordinary metrics export should accompany the narrow motion probe")
  }
  func testBoundedNumericStatistics() {
    let r = MetricsRecorder(capacity: 4)
    for x in 1...10 { r.record("scene_cpu_ms", milliseconds: Double(x)) }
    XCTAssertEqual(r.statistics("scene_cpu_ms")?.count, 10)
    XCTAssertEqual(r.statistics("scene_cpu_ms")?.retained, 4)
    XCTAssertEqual(r.statistics("scene_cpu_ms")?.p50, 8)
    XCTAssertEqual(r.rawSamples()["scene_cpu_ms"], [7, 8, 9, 10])
  }
}
