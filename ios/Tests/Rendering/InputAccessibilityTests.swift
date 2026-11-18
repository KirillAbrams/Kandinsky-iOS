import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class InputAccessibilityTests: XCTestCase {
  private func waitFor(_ predicate: () -> Bool) async throws {
    let end = Date().addingTimeInterval(5)
    while Date() < end {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(predicate(), "Native accessibility font/layout did not update")
  }
  private func check(_ view: UIView, inputID: String, sendID: String) async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      parent = UIViewController(), child = UIViewController()
    parent.addChild(child)
    child.view = view
    parent.view.addSubview(view)
    child.didMove(toParent: parent)
    window.rootViewController = parent
    window.makeKeyAndVisible()
    view.frame = window.bounds
    view.layoutIfNeeded()
    defer {
      window.isHidden = true
      previous?.makeKey()
    }
    let input = try XCTUnwrap(
      view.subviews.first { $0.accessibilityIdentifier == inputID } as? UITextView)
    let send = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier == sendID })
    let size = try XCTUnwrap(input.font).pointSize
    parent.setOverrideTraitCollection(
      UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
      forChild: child)
    try await waitFor { (input.font?.pointSize ?? 0) > size * 1.5 }
    try await waitFor { input.frame.height >= (input.font?.lineHeight ?? 0) + 6 }
    XCTAssertFalse(
      send.frame.intersects(input.frame.insetBy(dx: -1, dy: -1)),
      "Editable text and send target must not overlap in either axis")
    XCTAssertGreaterThanOrEqual(send.bounds.width, 44)
    XCTAssertGreaterThanOrEqual(send.bounds.height, 44)
  }
  func testComposerAdaptsInputAndHitTargetToLargeSystemFont() async throws {
    try await check(
      ConversationChrome(chatID: 3, onBack: {}), inputID: "composer.input", sendID: "composer.send")
  }
}
