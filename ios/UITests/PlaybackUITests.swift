// Открываем настоящие фото и видео из существующей медиаленты и проверяем управление просмотром.

import XCTest
import UIKit

final class PlaybackUITests: XCTestCase {
  private func openMediaHistory(_ app: XCUIApplication) throws {
    app.launch()
    let history = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", "Плотная медиалента")
    ).firstMatch
    if !history.exists {
      let menu = app.buttons["chat.back"]
      guard menu.waitForExistence(timeout: 10) else {
        throw XCTSkip("Для галереи нужен вход в аккаунт с медиалентой")
      }
      menu.tap()
    }
    XCTAssertTrue(history.waitForExistence(timeout: 15))
    history.tap()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 15))
  }

  private func visibleButton(_ label: String, in app: XCUIApplication) throws -> XCUIElement {
    let matching = app.buttons.matching(NSPredicate(format: "label == %@", label))
    for _ in 0..<8 {
      if let button = matching.allElementsBoundByIndex.first(where: { $0.isHittable }) {
        return button
      }
      app.swipeDown()
    }
    return try XCTUnwrap(matching.allElementsBoundByIndex.first(where: { $0.isHittable }))
  }

  func testGalleryReturnsToTheSameVideoAfterSlowAndFastSwipes() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    try openMediaHistory(app)
    try visibleButton("На весь экран", in: app).tap()
    let close = app.buttons["player.inline"]
    XCTAssertTrue(close.waitForExistence(timeout: 10))
    let title = app.staticTexts["viewer.item"]
    XCTAssertTrue(title.waitForExistence(timeout: 6))
    let videoTitle = title.label
    XCTAssertTrue(videoTitle.hasPrefix("Видео"))

    let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.48))
    let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.48))
    let photo = app.buttons["photo.close"]
    var photoOnLeft = true
    func swipe(towardLeft: Bool, velocity: XCUIGestureVelocity) {
      let start = towardLeft ? right : left
      start.press(
        forDuration: 0.06, thenDragTo: towardLeft ? left : right, withVelocity: velocity,
        thenHoldForDuration: 0.1)
    }
    swipe(towardLeft: photoOnLeft, velocity: .slow)
    if !photo.waitForExistence(timeout: 3) {
      if title.label != videoTitle {
        swipe(towardLeft: false, velocity: .slow)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, videoTitle)
      }
      photoOnLeft = false
      swipe(towardLeft: photoOnLeft, velocity: .slow)
    }
    XCTAssertTrue(photo.waitForExistence(timeout: 6))
    XCTAssertTrue(title.label.hasPrefix("Фото"))
    swipe(towardLeft: !photoOnLeft, velocity: .fast)
    XCTAssertTrue(close.waitForExistence(timeout: 6))
    XCTAssertEqual(title.label, videoTitle)
    swipe(towardLeft: photoOnLeft, velocity: .fast)
    XCTAssertTrue(photo.waitForExistence(timeout: 6))
    swipe(towardLeft: !photoOnLeft, velocity: .slow)
    XCTAssertTrue(close.waitForExistence(timeout: 6))
    XCTAssertEqual(title.label, videoTitle)
    XCUIDevice.shared.press(.home)
    let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.state == .runningBackground || app.state == .runningBackgroundSuspended
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 8), .completed)
    app.activate()
    XCTAssertTrue(close.waitForExistence(timeout: 8))
    XCTAssertEqual(title.label, videoTitle)

    var last = try centrePixels(in: app)
    var changedFrames = 0
    let plays = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let current = try? self.centrePixels(in: app) else { return false }
      if self.pixelDifference(last, current) > 1.5 { changedFrames += 1 }
      last = current
      return changedFrames >= 2
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [plays], timeout: 12), .completed)
    XCTAssertEqual(title.label, videoTitle)
    close.tap()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 10))
  }

  // Используем уже открытый аккаунт, заходим в «Плотную медиаленту» и находим доступные элементы.
  // Проверяем переход в просмотр и возврат к видео в ленте.
  func testPhotoAndVideoOpenFromExistingMediaHistory() throws {
    let app = XCUIApplication()
    try openMediaHistory(app)
    try visibleButton("Открыть фотографию", in: app).tap()
    let close = app.buttons["photo.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 10))
    let more = app.buttons["viewer.result.actions"]
    XCTAssertTrue(more.waitForExistence(timeout: 8))
    more.tap()
    let actions = app.sheets["Действия с результатом"]
    XCTAssertTrue(actions.waitForExistence(timeout: 8))
    XCTAssertTrue(actions.buttons["Удалить результат"].exists)
    let cancel = app.buttons["Отмена"].firstMatch
    if cancel.exists {
      cancel.tap()
    } else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.12)).tap()
    }
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: actions)
    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 6), .completed)
    XCTAssertTrue(close.waitForExistence(timeout: 8))

    let image = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
    image.tap()
    let hidden = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: close)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 6), .completed)
    XCTAssertFalse(more.exists)
    image.tap()
    XCTAssertTrue(close.waitForExistence(timeout: 8))
    XCTAssertTrue(more.exists)
    close.tap()
    try visibleButton("На весь экран", in: app).tap()
    let inline = app.buttons["player.inline"]
    XCTAssertTrue(inline.waitForExistence(timeout: 10))
    inline.tap()
  }

  func testZoomKeepsThePhotoOpenAndAFollowingVerticalSwipeClosesIt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    try openMediaHistory(app)
    try visibleButton("Открыть фотографию", in: app).tap()
    let close = app.buttons["photo.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 10))
    let loading = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["media.cancel"])
    XCTAssertEqual(XCTWaiter.wait(for: [loading], timeout: 12), .completed)

    let baseline = try centrePixels(in: app)
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.43))
    let nearby = app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.49))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.88))
    start.doubleTap()
    let zoomChangedPixels = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let zoomed = try? self.centrePixels(in: app) else { return false }
      return self.pixelDifference(baseline, zoomed) > 8
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [zoomChangedPixels], timeout: 6), .completed)

    start.press(forDuration: 0.07, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    XCTAssertTrue(close.isHittable)
    start.doubleTap()
    let zoomReset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let restored = try? self.centrePixels(in: app) else { return false }
      return self.pixelDifference(baseline, restored) < 3
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [zoomReset], timeout: 6), .completed)
    start.press(forDuration: 0.07, thenDragTo: nearby, withVelocity: .slow, thenHoldForDuration: 0.1)
    XCTAssertTrue(close.isHittable)
    start.press(forDuration: 0.07, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    let returned = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: close)
    XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed)
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 8))
  }

  private func centrePixels(in app: XCUIApplication) throws -> [UInt8] {
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let crop = try XCTUnwrap(image.cropping(to: CGRect(
      x: width * 0.22, y: height * 0.32, width: width * 0.56, height: height * 0.30)))
    let size = 24
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    return pixels
  }

  private func pixelDifference(_ first: [UInt8], _ second: [UInt8]) -> Double {
    let rgb = first.indices.filter { $0 % 4 != 3 }
    let total = rgb.reduce(0) { $0 + abs(Int(first[$1]) - Int(second[$1])) }
    return Double(total) / Double(rgb.count)
  }
}
