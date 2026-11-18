import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class ReflowAnchorTests: XCTestCase {
  func testNearbyRowKeepsPreparedBitmapThroughEntryAndReversal() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...100 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [.integer(Int64(n)), .text("Строка \(n)."), .integer(1_793_700_000_000 + Int64(n))])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    func nodes(_ root: CALayer) -> [MessageLayer] {
      (root.sublayers ?? []).flatMap { child in
        (child as? MessageLayer).map { [$0] } ?? nodes(child)
      }
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor { host.metrics.recordings >= 10 }
    try await Task.sleep(nanoseconds: 250_000_000)
    weak var witness = nodes(host.layer).first {
      $0.fragment?.id == FragmentID(messageID: 19, part: 0)
    }
    print(
      """
      KANDINSKY_NEIGHBOUR initialOffset=\(host.contentOffset.y) fragments=\(host.metrics.liveFragments) \
      preparedNeighbour=\(witness != nil)
      """
    )
    XCTAssertNotNil(
      witness,
      """
      A local row just beyond the viewport must be ready before a fast nearby scroll, rather than \
      admitted only after it appears
      """
    )
    guard witness != nil else {
      host.close()
      try await h.close()
      return
    }
    do {
      let node = try XCTUnwrap(witness), bitmap = try XCTUnwrap(node.contents as AnyObject?)
      let distance = node.frame.minY - host.bounds.maxY
      XCTAssertGreaterThanOrEqual(distance, 100)
      XCTAssertLessThanOrEqual(distance, 300)
      let initial = host.contentOffset.y
      host.setContentOffset(CGPoint(x: 0, y: initial + 240), animated: false)
      try await waitFor {
        self.textElements(host).contains { $0.accessibilityIdentifier == "message.19" }
      }
      XCTAssertTrue(nodes(host.layer).contains { $0 === node })
      XCTAssertTrue(
        (node.contents as AnyObject?) === bitmap,
        "The entering row must keep its already prepared bitmap")
      host.setContentOffset(CGPoint(x: 0, y: initial), animated: false)
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertTrue(nodes(host.layer).contains { $0 === node })
      XCTAssertTrue(
        (node.contents as AnyObject?) === bitmap,
        "A nearby reversal must reuse the same bounded raster")
      XCTAssertLessThanOrEqual(
        host.metrics.liveFragments, 64,
        "Preparing nearby rows must remain bounded independently of history length")
    }
    host.close()
    XCTAssertEqual(host.metrics.liveFragments, 0)
    // Системная транзакция освобождает отсоединённые слои после прохода основного потока
    try await Task.sleep(nanoseconds: 50_000_000)
    print("KANDINSKY_NEIGHBOUR detachedLayerAfterRunLoop=\(witness != nil)")
    XCTAssertNil(
      witness, "The native transaction must release the detached layer after the run-loop turn")
    try await h.close()
  }
  func testRepeatedLayoutInvalidationsShareARefresh() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...30 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [
              .integer(Int64(n)), .text("Неизменная строка \(n)."),
              .integer(1_793_700_000_000 + Int64(n))
            ])
        }
      }
    }
    let priorMotion = getenv("KANDINSKY_SCROLL_MOTION").map { String(cString: $0) }
    let priorOutput = MetricsRuntime.output, priorEnabled = MetricsRuntime.enabled
    let output = h.root.appendingPathComponent("refresh.json"),
      motion = h.root.appendingPathComponent("refresh-motion.json")
    setenv("KANDINSKY_SCROLL_MOTION", "1", 1)
    MetricsRuntime.output = output
    MetricsRuntime.enabled = false
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
      MetricsRuntime.output = priorOutput
      MetricsRuntime.enabled = priorEnabled
      if let priorMotion {
        setenv("KANDINSKY_SCROLL_MOTION", priorMotion, 1)
      } else {
        unsetenv("KANDINSKY_SCROLL_MOTION")
      }
    }
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor { host.metrics.liveFragments > 0 && host.metrics.recordings > 0 }
    try await Task.sleep(nanoseconds: 150_000_000)
    let labels = textElements(host).map { $0.accessibilityLabel },
      recordings = host.metrics.recordings
    let start = Date().timeIntervalSince1970
    for _ in 0..<200 {
      host.setNeedsLayout()
      host.layoutIfNeeded()
      try await Task.sleep(nanoseconds: 500_000)
    }
    let end = Date().timeIntervalSince1970
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(textElements(host).map { $0.accessibilityLabel }, labels)
    XCTAssertEqual(
      host.metrics.recordings, recordings,
      "Unchanged visible messages must retain their rasterized content")
    host.close()
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: motion.path), Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    struct Sample: Decodable { let epoch: Double, event: String, renderCount: Int }
    struct Report: Decodable { let dropped: Int, samples: [Sample] }
    let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: motion))
    let ticks = report.samples.filter {
      $0.event == "sample" && $0.epoch >= start && $0.epoch <= end
    }
    XCTAssertEqual(report.dropped, 0)
    XCTAssertGreaterThan(ticks.count, 2)
    let first = try XCTUnwrap(ticks.first), last = try XCTUnwrap(ticks.last),
      passes = last.renderCount - first.renderCount
    print(
      "KANDINSKY_SCENE_REFRESH fullPasses=\(passes) nativeRefreshSamples=\(ticks.count) seconds=\(end-start)"
    )
    XCTAssertGreaterThan(passes, 0, "The real invalidated scene must actually run")
    XCTAssertLessThanOrEqual(
      passes, ticks.count + 2, "Repeated layout callbacks must share screen refresh work")
    try await h.close()
  }
  func testColdPrecedingHeightKeepsPaintedWitnessAtEveryRunLoopBoundary() async throws {
    let h = try await RepositoryHarness.open()
    let long = String(repeating: "مرحبا длинное сообщение 👨‍👩‍👧‍👦 café, перенос строки.\n", count: 1800)
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...100 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [
              .integer(Int64(n)), .text(n == 1 ? long : "Стабильная строка \(n)."),
              .integer(1_793_700_000_000 + Int64(n))
            ])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    /// Рекурсивно обходит слои, чтобы наблюдать именно действительный нарисованный объект.
    func witness(_ root: CALayer) -> MessageLayer? {
      if let value = root as? MessageLayer, value.fragment?.id == FragmentID(messageID: 2, part: 0)
      {
        return value
      }
      for child in root.sublayers ?? [] { if let found = witness(child) { return found } }
      return nil
    }
    var initialHeight: CGFloat = 0, observations = 0, paintedBeforeGrowth = false,
      sawGrowth = false, largestDisplacement: CGFloat = 0
    let observer = try XCTUnwrap(
      CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { [weak host, weak window] _, _ in
        MainActor.assumeIsolated {
          guard let host, let window, initialHeight > 0, let node = witness(host.layer),
            node.contents != nil
          else { return }
          let grown = host.contentSize.height > initialHeight + 10_000
          if !grown { paintedBeforeGrowth = true }
          sawGrowth = sawGrowth || grown
          observations += 1
          let expected: CGFloat = 100
          let actual = node.convert(node.bounds, to: window.layer).minY
          largestDisplacement = max(largestDisplacement, abs(actual - expected))
        }
      })
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    defer {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
      CFRunLoopObserverInvalidate(observer)
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 2, followsBottom: false))
    initialHeight = host.contentSize.height
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline && !sawGrowth { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 150_000_000)
    print(
      """
      KANDINSKY_ATOMIC_HEIGHT observations=\(observations) paintedBeforeGrowth=\(paintedBeforeGrowth) \
      grew=\(sawGrowth) maxDisplacement=\(largestDisplacement)
      """
    )
    XCTAssertTrue(
      paintedBeforeGrowth,
      "The actual short witness must paint before the cold preceding measurement completes")
    XCTAssertTrue(
      sawGrowth, "The cold preceding row must actually replace its estimate by more than10000pt")
    XCTAssertGreaterThan(
      observations, 1, "A single settled observation cannot verify inter-turn consistency")
    XCTAssertLessThanOrEqual(
      largestDisplacement, 0.5,
      "With no user input, parent offset and retained child placement must agree at every main-run-loop boundary"
    )
    host.close()
    try await h.close()
  }
  func testNativeScrollRetainsAccessibilityObjectsAndActions() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...500 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [.integer(Int64(n)), .text("Строка \(n)."), .integer(1_793_700_000_000 + Int64(n))])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    var copied: String?
    host.onMessageAction = { row, action in if case .copy = action { copied = row.text } }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor {
      self.textElements(host).contains { $0.accessibilityIdentifier == "message.5" }
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    let before = try XCTUnwrap(
      textElements(host).first { $0.accessibilityIdentifier == "message.5" })
    let actions = try XCTUnwrap(before.accessibilityCustomActions),
      frame = before.accessibilityFrameInContainerSpace
    XCTAssertEqual(before.accessibilityLabel, "Строка 5.")
    XCTAssertEqual(actions.map(\.name), ["Копировать запрос"])
    let offset = host.contentOffset.y
    host.setContentOffset(CGPoint(x: 0, y: offset + 12), animated: false)
    try await Task.sleep(nanoseconds: 100_000_000)
    let after = try XCTUnwrap(
      textElements(host).first { $0.accessibilityIdentifier == "message.5" })
    let currentActions = try XCTUnwrap(after.accessibilityCustomActions)
    print(
      """
      KANDINSKY_ACCESSIBILITY_REUSE element=\(after === before) \
      action=\(currentActions.first === actions.first) visible=\(textElements(host).count)
      """
    )
    XCTAssertTrue(
      after === before,
      "An unchanged visible line must keep its native accessibility identity during ordinary scrolling"
    )
    XCTAssertTrue(
      currentActions.first === actions.first,
      "Existing actions must not allocate new closures on every scroll frame")
    XCTAssertEqual(
      after.accessibilityFrameInContainerSpace, frame,
      "Native scrolling translates the container; content-coordinate accessibility geometry remains fixed"
    )
    XCTAssertTrue(try XCTUnwrap(currentActions.first?.actionHandler)(currentActions[0]))
    XCTAssertEqual(copied, "Строка 5.")
    try await h.store.perform { db in
      try db.execute(
        "UPDATE messages SET text='Обновлённая строка.',revision=revision+1 WHERE id=5")
    }
    let chats = try await h.repo.chats(matching: "")
    host.apply(MessageDelta(chat: try XCTUnwrap(chats.first { $0.id == 2 }), reason: .sync))
    try await waitFor {
      self.textElements(host).contains {
        $0.accessibilityIdentifier == "message.5" && $0.accessibilityLabel == "Обновлённая строка."
      }
    }
    let revised = try XCTUnwrap(
      textElements(host).first { $0.accessibilityIdentifier == "message.5" })
    let copy = try XCTUnwrap(revised.accessibilityCustomActions?.first)
    XCTAssertTrue(try XCTUnwrap(copy.actionHandler)(copy))
    XCTAssertEqual(
      copied, "Обновлённая строка.",
      "A retained action must not keep an obsolete message after its revision changes")
    host.close()
    try await h.close()
  }
  /// После закрытия должны освободиться и текущие видимые элементы.
  func testAccessibilityWindowReleasesDepartedAndClosedElements() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...1000 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [.integer(Int64(n)), .text("Сообщение \(n)."), .integer(1_793_700_000_000 + Int64(n))])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor {
      self.textElements(host).contains { $0.accessibilityIdentifier == "message.5" }
    }
    weak var departed = textElements(host).first { $0.accessibilityIdentifier == "message.5" }
    XCTAssertNotNil(departed)
    host.setContentOffset(CGPoint(x: 0, y: 12_000), animated: false)
    try await waitFor {
      !self.textElements(host).isEmpty
        && !self.textElements(host).contains { $0.accessibilityIdentifier == "message.5" }
    }
    try await waitFor { departed == nil }
    XCTAssertLessThanOrEqual(
      textElements(host).count, 128,
      "Retention must remain bounded by the rendered viewport, not visited history")
    weak var visible = textElements(host).first
    XCTAssertNotNil(visible)
    host.close()
    try await waitFor { visible == nil }
    XCTAssertTrue(textElements(host).isEmpty)
    try await h.close()
  }
  func testRetainedMediaAccessibilityActivatesAtCurrentPositionAndCloses() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...100 {
          let kind = n == 1 ? "photo" : n == 2 ? "voice" : n == 3 ? "round" : "text"
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,?,?,?)",
            [
              .integer(Int64(n)), .text(kind), .text(n > 3 ? "Строка \(n)." : ""),
              .integer(1_793_700_000_000 + Int64(n))
            ])
          if n <= 3 {
            try db.execute(
              """
              INSERT INTO attachments(id,messageId,relativePath,mime,byteSize,width,height,\
              durationMs,thumbnailKey) \
              VALUES(?,?,?,'video/mp4',100,480,360,7000,'')
              """,
              [.text("accessibility-\(n)"), .integer(Int64(n)), .text("fixture-\(n)")])
          }
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    /// Возвращает действительный объект, чтобы проверить его повторное использование и действие.
    func media(_ id: String) -> UIAccessibilityElement? {
      host.subviews.flatMap {
        ($0.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
      }.first { $0.accessibilityIdentifier == id }
    }
    var activation: (MessageID, CGRect)?
    host.onMessageTap = { row, frame in activation = (row.id, frame) }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor {
      media("media.image.1") != nil && media("media.audio.2") != nil
        && media("media.image.3") != nil
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    weak var photo = media("media.image.1"), voice = media("media.audio.2"),
      round = media("media.image.3")
    let photoFrame = try XCTUnwrap(photo).accessibilityFrameInContainerSpace
    host.setContentOffset(CGPoint(x: 0, y: 12), animated: false)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(media("media.image.1") === photo)
    XCTAssertTrue(media("media.audio.2") === voice)
    XCTAssertTrue(media("media.image.3") === round)
    do {
      let element = try XCTUnwrap(media("media.image.1"))
      XCTAssertTrue(element.accessibilityActivate())
      XCTAssertEqual(activation?.0, 1)
      XCTAssertEqual(
        activation?.1, photoFrame.offsetBy(dx: 0, dy: -12),
        "Retained media actions must read the current viewport, not the offset captured when they were created"
      )
    }
    host.close()
    try await waitFor { photo == nil && voice == nil && round == nil }
    try await h.close()
  }
  private func textElements(_ host: ChatScrollHost) -> [UIAccessibilityElement] {
    host.subviews.flatMap {
      ($0.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    }.filter { ($0.accessibilityIdentifier ?? "").hasPrefix("message.") }
  }
  func testColdLongMessageHeightKeepsNativePixelPosition() async throws {
    let h = try await RepositoryHarness.open()
    let text = String(
      repeating: "Длинное сообщение, которое впервые готовится за экраном.\n", count: 240)
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...100 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [
              .integer(Int64(n)), .text(n == 1 ? text : "Короткая строка \(n)"),
              .integer(1_793_700_000_000 + Int64(n))
            ])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    parent.view.backgroundColor = .magenta
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    // Позиция задаётся сразу после открытия, пока первая точная раскладка ещё не получена
    host.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
    let before = host.contentOffset.y
    XCTAssertEqual(before, 200, accuracy: 0.1)
    XCTAssertEqual(
      host.metrics.recordings, 0,
      "A cached row would not exercise estimated-to-exact height replacement")
    XCTAssertNil(host.readingAnchor().textUTF16Offset)
    try await waitFor { host.metrics.recordings > 0 && host.readingAnchor().textUTF16Offset != nil }
    try await Task.sleep(nanoseconds: 100_000_000)
    print(
      """
      KANDINSKY_COLD_HEIGHT before=\(before) after=\(host.contentOffset.y) \
      height=\(host.contentSize.height) anchor=\(host.readingAnchor())
      """
    )
    XCTAssertEqual(host.readingAnchor().messageID, 1)
    XCTAssertEqual(
      host.contentOffset.y, before, accuracy: 1,
      "Preparing a cold long row must preserve pixels instead of scaling the old estimated height fraction"
    )
    host.close()
    try await h.close()
  }
  func testUIKitGeometryShiftComparedWithExplicitStop() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKey()
    }
    let controls = (0..<3).map { _ in
      UIScrollView(frame: CGRect(x: 0, y: 100, width: 390, height: 600))
    }
    for scroll in controls {
      scroll.contentSize = CGSize(width: 390, height: 200_000)
      window.rootViewController?.view.addSubview(scroll)
      scroll.setContentOffset(CGPoint(x: 0, y: 12_000), animated: true)
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    let opening = controls.map { $0.contentOffset.y }
    controls[0].setContentOffset(controls[0].contentOffset, animated: false)
    controls[1].contentOffset.y += 1
    controls[2].bounds.origin.y += 1
    try await Task.sleep(nanoseconds: 700_000_000)
    print(
      """
      KANDINSKY_UIKIT_SHIFT opening=\(opening) stop=\(controls[0].contentOffset.y) \
      property=\(controls[1].contentOffset.y) bounds=\(controls[2].contentOffset.y)
      """
    )
    XCTAssertLessThan(controls[0].contentOffset.y, 9_000)
    XCTAssertGreaterThan(
      controls[2].contentOffset.y, 9_000,
      "Telegram-style coordinate shift must preserve stock UIKit motion before being used in the renderer"
    )
  }
  /// Асинхронная раскладка не должна останавливать прокрутку на первом новом сообщении.
  func testAsyncRowLayoutDoesNotCancelNativeScrollMotion() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...1000 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text',?,?)",
            [
              .integer(Int64(n)),
              .text("Строка \(n). " + String(repeating: "Нативная прокрутка чата. ", count: 4)),
              .integer(1_793_700_000_000 + Int64(n))
            ])
        }
      }
    }
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    let parent = UIViewController(), host = ChatScrollHost()
    parent.view.backgroundColor = .magenta
    window.rootViewController = parent
    window.makeKeyAndVisible()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    let viewport = CGRect(x: 0, y: 100, width: 390, height: 600)
    let control = UIScrollView(frame: viewport)
    control.contentSize = CGSize(width: 390, height: 200_000)
    parent.view.addSubview(control)
    let distance: CGFloat = 12_000
    control.setContentOffset(CGPoint(x: 0, y: distance), animated: true)
    try await Task.sleep(nanoseconds: 700_000_000)
    XCTAssertGreaterThan(
      control.contentOffset.y, distance * 0.9, "Stock UIKit animation must work on this test host")
    control.removeFromSuperview()
    parent.view.addSubview(host)
    host.frame = viewport
    host.layoutIfNeeded()
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor { host.metrics.liveFragments > 0 }
    let recordings = host.metrics.recordings, start = host.contentOffset.y
    host.setContentOffset(CGPoint(x: 0, y: start + distance), animated: true)
    try await Task.sleep(nanoseconds: 700_000_000)
    let travelled = host.contentOffset.y - start
    print(
      """
      KANDINSKY_NATIVE_ANIMATION control=\(control.contentOffset.y) travelled=\(travelled) \
      newRecordings=\(host.metrics.recordings-recordings)
      """
    )
    XCTAssertGreaterThan(
      host.metrics.recordings, recordings, "The scroll must encounter newly prepared rows")
    XCTAssertGreaterThan(
      travelled, distance * 0.75,
      "Asynchronous row preparation must preserve native scroll motion instead of stopping near the first new row"
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.preferredRange = .standard
    let shot = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: shot)
    attachment.name = "native-visible-after-large-scroll"
    attachment.lifetime = .keepAlways
    add(attachment)
    let image = try XCTUnwrap(shot.cgImage)
    let pixels = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
    var white = 0
    for y in 150..<min(650, image.height) {
      for x in 0..<image.width {
        let i = (y * image.width + x) * 4
        if data[i] > 220 && data[i + 1] > 220 && data[i + 2] > 220 { white += 1 }
      }
    }
    print(
      "KANDINSKY_NATIVE_VISIBLE_PIXELS white=\(white) offset=\(host.contentOffset) bounds=\(host.bounds)"
    )
    for view in host.subviews
    where view.layer.sublayers?.contains(where: { $0 is MessageLayer }) == true {
      print(
        "KANDINSKY_NATIVE_PLANE frame=\(view.frame) bounds=\(view.bounds) screen=\(view.convert(view.bounds,to:window))"
      )
      for layer in view.layer.sublayers ?? [] {
        if let row = layer as? MessageLayer {
          print(
            """
            KANDINSKY_NATIVE_ROW frame=\(row.frame) screen=\(row.convert(row.bounds,to:window.layer)) \
            contents=\(row.contents != nil)
            """
          )
          break
        }
      }
    }
    XCTAssertGreaterThan(
      white, 1000,
      "Messages must be visible in actual window pixels after a large native scroll, not only in accessibility"
    )
    host.close()
    try await h.close()
  }
  func testNativeScrollDoesNotRepositionRetainedContentLayers() async throws {
    let h = try await RepositoryHarness.open()
    let delta = try await h.repo.send(
      SendCommand(
        operationID: "native-coordinate-test", chatID: 2,
        text: String(repeating: "Неподвижная строка содержимого чата.\n", count: 300)))
    let id = try XCTUnwrap(delta.inserted.first?.id)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost()
    parent.view.backgroundColor = .magenta
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 100, width: 390, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: id, followsBottom: false))
    try await waitFor { host.metrics.recordings >= 3 }
    host.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
    try await Task.sleep(nanoseconds: 100_000_000)
    func nodes(_ root: CALayer) -> [MessageLayer] {
      (root.sublayers ?? []).flatMap { child in
        (child as? MessageLayer).map { [$0] } ?? nodes(child)
      }
    }
    let node = try XCTUnwrap(
      nodes(host.layer).first { $0.fragment?.id == FragmentID(messageID: id, part: 1) })
    let frame = node.frame, screen = node.convert(node.bounds, to: window.layer),
      offset = host.contentOffset.y
    let bitmap = try XCTUnwrap(node.contents as AnyObject?)
    host.setContentOffset(CGPoint(x: 0, y: offset + 12), animated: false)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(nodes(host.layer).contains { $0 === node })
    XCTAssertEqual(
      node.frame, frame,
      """
      Retained message geometry belongs to content coordinates; native scroll already provides the \
      viewport translation
      """
    )
    XCTAssertEqual(
      node.convert(node.bounds, to: window.layer).minY, screen.minY - 12, accuracy: 0.5)
    XCTAssertTrue(
      (node.contents as AnyObject?) === bitmap,
      "The retained fragment must reuse its bitmap; newly exposed fragments may rasterize separately"
    )
    host.close()
    try await h.close()
  }
  func testCancelledOffscreenLayoutsYieldToTheNewViewport() async throws {
    let worker = TextLayoutWorker()
    defer { worker.close() }
    let text = String(repeating: "مرحبا сообщение 👨‍👩‍👧‍👦 café ", count: 1500)
    func row(_ id: Int64, _ value: String) -> Message {
      Message(
        id: id, chatID: 4, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1, kind: .text, text: value, caption: "", replyToID: nil, revision: 1,
        attachments: [])
    }
    let cancelled = expectation(description: "Cancelled layouts never publish partial text")
    cancelled.expectedFulfillmentCount = 2
    let tokens = (1...2).map { id in
      worker.prepare(
        message: row(Int64(id), text),
        key: TextLayoutKey(messageID: Int64(id), revision: 1, width: 200, fontSize: 18, scale: 3),
        ticket: 1
      ) { _, resource in
        XCTAssertNil(resource)
        resource?.close()
        cancelled.fulfill()
      }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    tokens.forEach { $0.cancel() }
    let ready = expectation(
      description: "New viewport paints while obsolete long messages are cancelled")
    let start = Date()
    worker.prepare(
      message: row(3, "Текущий экран"),
      key: TextLayoutKey(messageID: 3, revision: 1, width: 200, fontSize: 18, scale: 3), ticket: 1
    ) { _, resource in
      XCTAssertNotNil(resource)
      resource?.close()
      print("KANDINSKY_CANCELLED_LAYOUT_WAIT \(Date().timeIntervalSince(start))")
      ready.fulfill()
    }
    await fulfillment(of: [ready, cancelled], timeout: 0.25)
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    let end = Date().addingTimeInterval(6)
    while Date() < end {
      if condition() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition())
  }
  private func check(font: Bool) async throws {
    let h = try await RepositoryHarness.open()
    let value = String(repeating: "مرحبا 👨‍👩‍👧‍👦 café é Unicode line ", count: 600)
    _ = try await h.repo.send(SendCommand(operationID: "reflow", chatID: 2, text: value))
    let host = ChatScrollHost(), parent = UIViewController(), child = UIViewController()
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene)
    parent.addChild(child)
    child.view = host
    parent.view.addSubview(host)
    child.didMove(toParent: parent)
    window.rootViewController = parent
    window.makeKeyAndVisible()
    host.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      previous?.makeKey()
    }
    try await host.open(
      chatID: 2, repository: h.repo, anchor: ReadingAnchor(messageID: 1, followsBottom: false))
    try await waitFor { host.metrics.liveFragments > 0 }
    host.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
    host.layoutIfNeeded()
    let before = host.readingAnchor(), recorded = host.metrics.recordings,
      height = host.contentSize.height
    XCTAssertNotNil(before.textUTF16Offset)
    XCTAssertGreaterThan(before.textUTF16Offset ?? 0, 0)
    if font {
      parent.setOverrideTraitCollection(
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
        forChild: child)
      try await waitFor {
        host.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge
      }
    } else {
      host.frame.size.width = 390
      host.setNeedsLayout()
      host.layoutIfNeeded()
    }
    try await waitFor {
      host.metrics.recordings > recorded && host.metrics.liveFragments > 0
        && (font ? host.contentSize.height > height * 1.2 : host.contentSize.height < height * 0.99)
    }
    let after = host.readingAnchor()
    XCTAssertEqual(after.messageID, before.messageID)
    XCTAssertEqual(
      after.textUTF16Offset, before.textUTF16Offset,
      "Preserve logical UTF16 position after actual new text layout")
    host.close()
    try await h.close()
  }
  func testWidthReflowKeepsLogicalUnicodePosition() async throws { try await check(font: false) }
  func testLargeFontActuallyRelayoutsAndKeepsLogicalUnicodePosition() async throws {
    try await check(font: true)
  }
}
