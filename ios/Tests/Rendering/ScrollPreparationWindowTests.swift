import XCTest
import UIKit
@testable import Kandinsky

final class ScrollPreparationWindowTests: XCTestCase {
  #if DEBUG
  @MainActor func testScrollingWithinReadyRowsReusesTheWindowAndFollowsGeometryChanges() throws {
    let host = ChatScrollHost()
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    defer { host.close() }

    let rows = (1...8).map { number in
      let id = Int64(number)
      return Message(
        id: id, chatID: 1, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1_793_700_000_000 + id, kind: .text, text: "Строка \(id)", caption: "",
        replyToID: nil, revision: 0, attachments: [])
    }
    let indexed = rows.map { row in
      IndexedRow(messageID: row.id, order: row.order, estimatedHeight: 80, revision: row.revision,
        savedAtMs: row.savedAtMs)
    }
    let anchor = ReadingAnchor()
    _ = try host.index.replace(rows: indexed, anchor: anchor, viewport: 400)
    host.contentSize = CGSize(width: 390, height: host.index.totalHeight)
    for row in rows {
      host.loaded[row.id] = row
      host.cache.insert(PreparedText(message: row, key: host.key(row)))
    }

    var reads: [MessageID] = []
    host.onPreparedRowLookup = { reads.append($0) }
    host.render()
    XCTAssertEqual(reads, rows.map(\.id))
    let second = try XCTUnwrap(host.plane.layer.sublayers?.compactMap { $0 as? MessageLayer }
      .first { $0.fragment?.id.messageID == 2 })
    let oldTop = second.frame.minY
    let initialReconciliations = host.scene.metrics.windowReconciliations
    reads.removeAll()

    for offset in stride(from: 6, through: 48, by: 6) {
      host.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      host.render()
      XCTAssertEqual(host.scene.imageViewport?.minY, CGFloat(offset))
      XCTAssertEqual(second.frame.minY, oldTop)
    }
    XCTAssertTrue(reads.isEmpty, "Moving within the same prepared window needs no layout lookups")
    XCTAssertEqual(host.scene.metrics.windowReconciliations, initialReconciliations,
      "A fractional viewport shift must not reassess which prepared layers belong to the window")
    reads.removeAll()

    _ = try host.index.updateHeight(id: 1, height: 120, anchor: anchor, viewport: 400)
    host.render()
    XCTAssertEqual(reads, rows.map(\.id))
    XCTAssertEqual(second.frame.minY, oldTop + 40, accuracy: 0.01)
    XCTAssertEqual(host.scene.metrics.windowReconciliations, initialReconciliations + 1)
  }

  @MainActor func testPreparedFragmentWindowReconcilesInclusiveEdgesAndNewSceneGeneration() throws {
    let host = ChatScrollHost()
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    defer { host.close() }

    let rows = [Int64(1), 2].map { id in
      let message = Message(
        id: id, chatID: 1, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1_793_700_000_000 + id, kind: .text, text: "Строка", caption: "",
        replyToID: nil, revision: 0, attachments: [])
      return PreparedChatRowWindow.Row(
        message: message, layout: PreparedText(message: message, key: host.key(message)),
        origin: CGPoint(x: 6, y: CGFloat(id) * 100))
    }
    let window = PreparedChatRowWindow(
      key: .init(range: 0..<2, geometryRevision: 0, layoutRevision: 0, viewWidth: 390,
        layoutWidth: 390, fontSize: host.fontSize, screenScale: 3),
      rows: rows)
    let firstBlock = try XCTUnwrap(rows[0].layout.blocks.first)
    let firstEnd = rows[0].origin.y + firstBlock.offsetY + firstBlock.height
    let secondBlock = try XCTUnwrap(rows[1].layout.blocks.first)
    let secondStart = rows[1].origin.y + secondBlock.offsetY
    let ticket = host.scene.ticket

    let first = window.snapshot(top: firstEnd - 1, bottom: secondStart - 1, ticket: ticket)
    XCTAssertEqual(first.fragments.map(\.id.messageID), [1])
    XCTAssertTrue(window.snapshot(top: firstEnd, bottom: secondStart - 0.5, ticket: ticket) === first)

    let both = window.snapshot(top: firstEnd, bottom: secondStart, ticket: ticket)
    XCTAssertEqual(both.fragments.map(\.id.messageID), [1, 2])
    host.scene.apply(both)
    let retained = host.scene.nodeIdentity(for: .init(messageID: 2, part: 0))
    XCTAssertNotNil(retained)

    let second = window.snapshot(top: firstEnd + 0.5, bottom: secondStart, ticket: ticket)
    XCTAssertEqual(second.fragments.map(\.id.messageID), [2])
    host.scene.apply(second)
    XCTAssertNil(host.scene.nodeIdentity(for: .init(messageID: 1, part: 0)))
    XCTAssertEqual(host.scene.nodeIdentity(for: .init(messageID: 2, part: 0)), retained)

    host.scene.advanceGeneration()
    let fresh = window.snapshot(top: firstEnd + 0.5, bottom: secondStart, ticket: host.scene.ticket)
    XCTAssertFalse(fresh === second)
    host.scene.apply(second)
    XCTAssertEqual(host.scene.metrics.liveFragments, 0)
    host.scene.apply(fresh)
    XCTAssertEqual(host.scene.metrics.liveFragments, 1)
  }

  @MainActor func testDistanceIsCalculatedOnlyForMissingLayouts() throws {
    let host = ChatScrollHost()
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    defer { host.close() }

    let rows = (1...20).map { number in
      let id = Int64(number)
      return Message(
        id: id, chatID: 1, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1_793_700_000_000 + id, kind: .text, text: "Строка \(id)", caption: "",
        replyToID: nil, revision: 0, attachments: [])
    }
    let indexedRows = rows.map { row in
      IndexedRow(
        messageID: row.id, order: row.order, estimatedHeight: 44, revision: row.revision,
        savedAtMs: row.savedAtMs)
    }
    _ = try host.index.replace(rows: indexedRows, anchor: ReadingAnchor(), viewport: 400)
    host.contentSize = CGSize(width: 390, height: host.index.totalHeight)
    for row in rows {
      host.loaded[row.id] = row
      host.cache.insert(PreparedText(message: row, key: host.key(row)))
    }

    var reads: [MessageID] = []
    host.onLayoutPriorityDistance = { reads.append($0) }
    host.render()
    XCTAssertEqual(reads, [], "Ready rows must not be ranked again as preparation jobs")

    let missing: MessageID = 5
    host.cache.clear()
    for row in rows where row.id != missing {
      host.cache.insert(PreparedText(message: row, key: host.key(row)))
    }
    reads.removeAll()
    host.render()
    XCTAssertEqual(reads, [missing], "Rank the pending row exactly once")
    XCTAssertEqual(host.inFlight.keys.map(\.messageID), [missing])
  }
  #endif

  @MainActor func testInteriorFlingKeepsItsReleasePositionAndCanBeCaught() throws {
    var now = CACurrentMediaTime()
    let host = ChatScrollHost(scrollClock: { now })
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    host.contentSize = CGSize(width: 390, height: 4000)
    host.contentOffset = CGPoint(x: 0, y: 800)
    defer { host.close() }

    var landing = CGPoint(x: 0, y: 1200)
    host.delegate?.scrollViewWillEndDragging?(
      host, withVelocity: CGPoint(x: 0, y: 0.84), targetContentOffset: &landing)
    XCTAssertEqual(landing.y, 800, accuracy: 0.01)
    host.scrollViewDidEndDragging(host, willDecelerate: false)
    XCTAssertEqual(host.contentOffset.y, 1200, accuracy: 0.01)

    let animation = try XCTUnwrap(host.plane.layer.animationKeys()?.compactMap {
      host.plane.layer.animation(forKey: $0) as? CAKeyframeAnimation
    }.first)
    let values = try XCTUnwrap(animation.values as? [NSNumber])
    XCTAssertTrue(animation.isAdditive)
    XCTAssertEqual(animation.keyPath, "position.y")
    XCTAssertEqual(try XCTUnwrap(values.first).doubleValue, 400, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(values.last).doubleValue, 0, accuracy: 0.01)

    now += 0.12
    host.interruptCompositorFlight()
    XCTAssertGreaterThan(host.contentOffset.y, 800)
    XCTAssertLessThan(host.contentOffset.y, 1200)
    XCTAssertTrue(host.plane.layer.animationKeys()?.isEmpty ?? true)
  }

  @MainActor func testTouchCatchKeepsThePresentedPathUntilTheNextDisplay() throws {
    for destination: CGFloat in [400, 1200] {
      var now = CACurrentMediaTime()
      let host = ChatScrollHost(scrollClock: { now }, canUseCompositorInertia: true)
      host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
      host.contentSize = CGSize(width: 390, height: 4000)
      let start: CGFloat = 800
      host.contentOffset = CGPoint(x: 0, y: start)
      defer { host.close() }

      var landing = CGPoint(x: 0, y: destination)
      let velocity: CGFloat = destination > start ? 0.84 : -0.84
      host.scrollViewWillEndDragging(
        host, withVelocity: CGPoint(x: 0, y: velocity), targetContentOffset: &landing)
      host.scrollViewDidEndDragging(host, willDecelerate: false)
      let originalKey = try XCTUnwrap(host.plane.layer.animationKeys()?.first)
      let original = try XCTUnwrap(host.plane.layer.animation(forKey: originalKey))
      now += 0.12
      host.scrollViewWillBeginDragging(host)

      let brake = try XCTUnwrap(host.plane.layer.animation(forKey: originalKey) as? CAKeyframeAnimation)
      XCTAssertNil(host.compositorFlight)
      XCTAssertEqual(brake.beginTime, original.beginTime)
      XCTAssertGreaterThan(brake.duration, 0.12)
      XCTAssertLessThan(brake.duration, 0.16)
      XCTAssertTrue(brake.isAdditive)
      let values = try XCTUnwrap(brake.values as? [NSNumber])
      XCTAssertEqual(host.contentOffset.y - CGFloat(values[0].doubleValue), start, accuracy: 0.01)
      XCTAssertEqual(values.last?.doubleValue, 0)
      XCTAssertLessThan(abs(host.contentOffset.y - start), abs(destination - start))

      host.pauseForNavigation()
      XCTAssertNil(host.plane.layer.animation(forKey: originalKey))
    }
  }

  @MainActor func testLateLayoutNearBottomPreservesTheVisibleRowAndInertia() throws {
    var now = CACurrentMediaTime()
    let host = ChatScrollHost(scrollClock: { now }, canUseCompositorInertia: true)
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    defer { host.close() }
    let messages = (1...16).map { sequence -> Message in
      let id = Int64(sequence)
      return Message(
        id: id, chatID: 1, order: OrderKey(sortKey: id, messageID: id), direction: .incoming,
        savedAtMs: 1_793_700_000_000 + id, kind: .text, text: "Строка", caption: "",
        replyToID: nil, revision: 0, attachments: [])
    }
    _ = try host.index.replace(rows: messages.map {
      IndexedRow(messageID: $0.id, order: $0.order, estimatedHeight: 100, revision: $0.revision,
        savedAtMs: $0.savedAtMs)
    }, anchor: ReadingAnchor(), viewport: 400)
    for row in messages {
      let layoutKey = host.key(row)
      host.loaded[row.id] = row
      host.cache.insert(PreparedText(message: row, key: layoutKey))
    }
    // Задаём те же отступы, которые используются при пересчёте высот.
    host.index.configureInsets(top: 8, bottom: 8)
    host.contentSize = CGSize(width: 390, height: CGFloat(host.index.totalHeight))
    let end = host.contentSize.height - host.bounds.height
    host.contentOffset = CGPoint(x: 0, y: end - 21)
    var landing = CGPoint(x: 0, y: end - 4)
    host.scrollViewWillEndDragging(
      host, withVelocity: CGPoint(x: 0, y: 0.84), targetContentOffset: &landing)
    host.scrollViewDidEndDragging(host, willDecelerate: false)
    XCTAssertNotNil(host.compositorFlight)
    now += 0.04
    host.sampleCompositorFlight(at: now)
    let oldOffset = host.viewportOffsetY
    let rowAbove = try XCTUnwrap(messages.first)
    host.pendingHeights[rowAbove.id] = (host.key(rowAbove), 118)

    host.render()

    XCTAssertNotNil(host.compositorFlight, "Preparing a row above the screen must not stop a fling")
    XCTAssertEqual(host.viewportOffsetY, oldOffset + 18, accuracy: 0.35,
      "Preparing a row above the screen must preserve the story position even near the bottom")
  }

  @MainActor func testInertiaRebasesWithoutRestartingItsLayerAnimation() throws {
    var now = CACurrentMediaTime()
    let host = ChatScrollHost(scrollClock: { now }, canUseCompositorInertia: true)
    host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
    host.contentSize = CGSize(width: 390, height: 4000)
    host.contentOffset = CGPoint(x: 0, y: 800)
    defer { host.close() }

    var landing = CGPoint(x: 0, y: 1200)
    host.scrollViewWillEndDragging(
      host, withVelocity: CGPoint(x: 0, y: 0.84), targetContentOffset: &landing)
    host.scrollViewDidEndDragging(host, willDecelerate: false)
    let animationKey = try XCTUnwrap(host.plane.layer.animationKeys()?.first)
    let startTime = try XCTUnwrap(host.plane.layer.animation(forKey: animationKey)).beginTime

    now += 0.14
    host.sampleCompositorFlight(at: now)
    let beforeReflow = host.viewportOffsetY
    XCTAssertGreaterThan(beforeReflow, 800)
    XCTAssertLessThan(beforeReflow, 1200)
    host.rebaseCompositorFlight(to: beforeReflow + 35)
    host.render()
    XCTAssertEqual(host.scene.imageViewport?.minY, host.viewportOffsetY)
    XCTAssertEqual(host.viewportOffsetY, beforeReflow + 35, accuracy: 0.001)
    XCTAssertEqual(host.contentOffset.y, 1235, accuracy: 0.001)
    XCTAssertEqual(host.plane.layer.animation(forKey: animationKey)?.beginTime, startTime)

    now += 2
    host.sampleCompositorFlight(at: now)
    XCTAssertEqual(host.viewportOffsetY, 1235, accuracy: 0.001)
    XCTAssertNil(host.plane.layer.animation(forKey: animationKey))
  }

  @MainActor func testBoundaryAndDisabledInertiaKeepTheNativeLanding() {
    for enabled in [true, false] {
      let host = ChatScrollHost(canUseCompositorInertia: enabled)
      host.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
      host.contentSize = CGSize(width: 390, height: 4000)
      host.contentOffset = CGPoint(x: 0, y: 3200)
      defer { host.close() }

      let expected: CGFloat = enabled ? 3600 : 3450
      var landing = CGPoint(x: 0, y: expected)
      host.scrollViewWillEndDragging(
        host, withVelocity: CGPoint(x: 0, y: 0.84), targetContentOffset: &landing)
      host.scrollViewDidEndDragging(host, willDecelerate: true)
      XCTAssertEqual(landing.y, expected)
      XCTAssertNil(host.compositorFlight)
      XCTAssertTrue(host.plane.layer.animationKeys()?.isEmpty ?? true)
    }
  }

  func testMediaLeadStaysWithinThreeShortViewportsEvenBeforeTheNextMotionSample() {
    var window = ScrollPreparationWindow()
    window.observe(offset: 10000, at: 1, viewport: 150)
    XCTAssertLessThanOrEqual(window.mediaBefore, 450)
    XCTAssertLessThanOrEqual(window.mediaAfter, 450)
    window.observe(offset: 8000, at: 1.02, viewport: 150)
    XCTAssertLessThanOrEqual(window.mediaBefore, 450)
    window.observe(offset: 8000, at: 1.021, viewport: 60)
    XCTAssertLessThanOrEqual(window.mediaBefore, 180)
    XCTAssertLessThanOrEqual(window.mediaAfter, 180)
    window.observe(offset: 8000, at: 2, viewport: 60)
    XCTAssertLessThanOrEqual(window.mediaBefore, 180)
  }

  @MainActor func testFastPreparationKeepsCurrentShortRowsInsideTheFragmentLimit() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { db in
      try db.transaction {
        for n in 1...1000 {
          try db.execute(
            "INSERT INTO messages(chatId,sortKey,kind,text,savedAt) VALUES(2,?,'text','Коротко.',?)",
            [.integer(Int64(n)), .integer(1_793_700_000_000 + Int64(n))])
        }
      }
    }
    var inputTime = 1.0
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let prior = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), host = ChatScrollHost(scrollClock: { inputTime })
    window.rootViewController = parent
    window.makeKeyAndVisible()
    parent.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 80, width: 390, height: 680)
    host.layoutIfNeeded()
    defer {
      host.close()
      window.isHidden = true
      prior?.makeKey()
    }
    try await host.open(chatID: 2, repository: h.repo, anchor: ReadingAnchor())
    try await Task.sleep(nanoseconds: 500_000_000)
    for _ in 0..<4 {
      inputTime += 1.0 / 60
      host.setContentOffset(CGPoint(x: 0, y: host.contentOffset.y - 1800), animated: false)
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 700_000_000)
    let windowState = try XCTUnwrap(
      Mirror(reflecting: host).children.first { $0.label == "preparation" }?.value
        as? ScrollPreparationWindow)
    XCTAssertGreaterThan(
      windowState.before, 5000, "Exercise the bounded fast-scroll runway, not a default500pt window"
    )
    let index = try XCTUnwrap(
      Mirror(reflecting: host).children.first { $0.label == "index" }?.value as? HistoryIndex)
    let visible = index.visible(
      offset: Double(host.contentOffset.y), height: Double(host.bounds.height), overscan: 0
    ).map { index.rows[$0].messageID }
    let nodes = host.subviews.flatMap {
      ($0.layer.sublayers ?? []).compactMap { $0 as? MessageLayer }
    }
    let painted = Set(nodes.compactMap { $0.contents != nil ? $0.fragment?.id.messageID : nil })
    print(
      "KANDINSKY_SHORT_RUNWAY required=\(visible) painted=\(painted.sorted()) runway=\(windowState.before)"
    )
    XCTAssertTrue(
      Set(visible).isSubset(of: painted),
      "The128fragment cap must not select only ahead-of-screen rows and exclude the current screen")
    XCTAssertLessThanOrEqual(nodes.count, 128)
    let mediaWindow = try XCTUnwrap(host.scene.imagePreparationViewport)
    XCTAssertLessThanOrEqual(mediaWindow.minY, host.contentOffset.y - host.bounds.height * 2,
      "Fast motion needs more than two screens of media lead, not a fixed600pt window")
    XCTAssertGreaterThanOrEqual(mediaWindow.maxY, host.contentOffset.y + host.bounds.height)
    host.close()
    try await h.close()
  }
  func testRunwayFollowsMotionAndHasFixedPixelAndViewportBounds() {
    var window = ScrollPreparationWindow()
    window.observe(offset: 10000, at: 1, viewport: 680)
    window.observe(offset: 9000, at: 1 + 1.0 / 60, viewport: 680)
    XCTAssertEqual(window.before, 4500, accuracy: 0.001)
    XCTAssertEqual(window.after, 500)
    window.observe(offset: 1000000, at: 1 + 2.0 / 60, viewport: 680)
    XCTAssertEqual(window.before, 500)
    XCTAssertEqual(window.after, 5440)
    window.observe(offset: 0, at: 1 + 3.0 / 60, viewport: 1200)
    XCTAssertEqual(window.before, 6144)
    XCTAssertEqual(window.after, 500)
  }
  /// Запас подготовки должен совпасть, поскольку перенос координат не является движением пальца.
  func testHeightRebaseDoesNotCreateFalseVelocityOrChangeDirection() {
    var reference = ScrollPreparationWindow(), rebased = ScrollPreparationWindow()
    reference.observe(offset: 5000, at: 1, viewport: 680)
    rebased.observe(offset: 5000, at: 1, viewport: 680)
    reference.observe(offset: 4900, at: 1 + 1.0 / 60, viewport: 680)
    rebased.rebase(by: 50000)
    rebased.observe(offset: 54900, at: 1 + 1.0 / 60, viewport: 680)
    XCTAssertEqual(rebased.before, reference.before, accuracy: 0.001)
    XCTAssertEqual(rebased.after, reference.after)
  }
  func testInputPacketAccumulationIdleAndInvalidValuesStayBounded() {
    var window = ScrollPreparationWindow()
    window.observe(offset: 10000, at: 1, viewport: 680)
    for n in 1...3 {
      window.observe(offset: 10000 - Double(n) * 100, at: 1 + Double(n) * 0.001, viewport: 680)
    }
    XCTAssertEqual(window.before, 500)
    window.observe(offset: 9000, at: 1.02, viewport: 680)
    XCTAssertGreaterThan(window.before, 500)
    window.observe(offset: .infinity, at: 1.03, viewport: 680)
    XCTAssertLessThanOrEqual(window.before, 5440)
    window.observe(offset: 8999, at: 2, viewport: 680)
    XCTAssertEqual(window.before, 500)
    XCTAssertEqual(window.after, 500)
    window.reset()
    XCTAssertEqual(window.before, 500)
    XCTAssertEqual(window.after, 500)
  }
}
