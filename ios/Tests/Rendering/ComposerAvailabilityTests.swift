import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class ComposerAvailabilityTests: XCTestCase {
  func testOnlySendableDraftEnablesNativeSendAndSuccessDisablesItAgain() async throws {
    let h = try await RepositoryHarness.open(), model = ConversationState(repository: h.repo)
    let view = ConversationChrome(chatID: 2, state: model, onBack: {})
    try await model.open(chatID: 2)
    try await view.openHistory(repository: h.repo, anchor: nil)
    let input = try XCTUnwrap(
      view.subviews.first { $0.accessibilityIdentifier == "composer.input" } as? UITextView)
    let send = try XCTUnwrap(
      view.subviews.first { $0.accessibilityIdentifier == "composer.send" } as? UIControl)
    XCTAssertFalse(send.isEnabled, "Empty local draft must not expose a send action")
    input.text = " \n "
    input.delegate?.textViewDidChange?(input)
    XCTAssertFalse(send.isEnabled)
    input.text = "готово"
    input.delegate?.textViewDidChange?(input)
    XCTAssertTrue(send.isEnabled)
    send.sendActions(for: .touchUpInside)
    let end = Date().addingTimeInterval(5)
    while !model.draft.text.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(model.draft.text.isEmpty)
    XCTAssertFalse(send.isEnabled)
    let count = try await h.messageCount(chatID: 2)
    XCTAssertEqual(count, 1)
    view.persistAnchorAndClose()
    await model.close()
    try await h.close()
  }
}
