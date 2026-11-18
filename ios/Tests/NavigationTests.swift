import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class NavigationTests: XCTestCase {
  func testSavedPhotoDraftRestoresAllGenerationOptionsAfterReopeningSQLite() async throws {
    var h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let photo = try await media.stageSelection(sourceURL: fixture, mime: "image/jpeg")
    let original = Draft(text: "Продолжить выбранную генерацию", attachmentDrafts: [photo])
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["generationOptions"] = [
      "model": "video", "aspect": "3:5", "duration_seconds": 1,
      "quality": "standard", "resolution": "compact", "count": 3, "seed": 127,
      "negative_prompt": "Keep the original scene", "guidance_scale": 4.0,
    ]
    let draft = try JSONDecoder().decode(
      Draft.self, from: JSONSerialization.data(withJSONObject: object))
    try await h.repo.saveDraft(chatID: 2, draft: draft)
    media.close()
    h = try await h.reopen()
    try await h.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(
      profile: NetworkProfile(
        userId: 1, deviceId: UUID().uuidString, name: "Options fixture",
        token: String(repeating: "a", count: 64), expiresAtMs: Int64.max),
      store: h.store, local: h.repo)
    let state = ConversationState(repository: h.repo)
    let view = ConversationChrome(chatID: 2, state: state, onBack: {})
    view.configureNetwork(sync)
    try await state.open(chatID: 2)
    XCTAssertEqual(view.generationOptions, requestedVideoOptions)
    let encoded = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(try await h.repo.draft(chatID: 2))) as? [String: Any]
    XCTAssertNotNil(encoded?["generationOptions"], "Параметры должны остаться в настоящей базе")
    await state.close()
    view.persistAnchorAndClose()
    sync.close()
    try await h.close()
  }

  func testPhotoConversationReturnsEverySelectedOptionWhenNavigating() async throws {
    let h = try await RepositoryHarness.open()
    try await h.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(
      profile: NetworkProfile(
        userId: 1, deviceId: UUID().uuidString, name: "Options fixture",
        token: String(repeating: "a", count: 64), expiresAtMs: Int64.max),
      store: h.store, local: h.repo)
    let media = MediaStore(store: h.store)
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("media/photo-000.jpg")
    let photo = try await media.stageSelection(sourceURL: fixture, mime: "image/jpeg")
    let state = ConversationState(repository: h.repo)
    let view = ConversationChrome(chatID: 0, state: state, onBack: {})
    view.configureNetwork(sync)
    view.openStudioDraft(Draft(text: "Фото", attachmentDrafts: [photo]))
    view.restoreGenerationOptions(requestedVideoOptions)
    XCTAssertEqual(view.generationOptions, requestedVideoOptions)
    await state.close()
    view.persistAnchorAndClose()
    media.close()
    sync.close()
    try await h.close()
  }

  func testLegacyDraftWithoutGenerationOptionsKeepsTheExistingFallback() throws {
    let data = Data(#"{"text":"Прежний текст","attachmentDrafts":[],"revision":0}"#.utf8)
    let draft = try JSONDecoder().decode(Draft.self, from: data)
    XCTAssertEqual(draft.text, "Прежний текст")
    XCTAssertEqual(draft.revision, 0)
    XCTAssertTrue(draft.attachmentDrafts.isEmpty)
  }

  private var requestedVideoOptions: KandinskyOptions {
    KandinskyOptions(
      model: "video", aspect: "3:5", duration_seconds: 1, quality: "standard",
      resolution: "compact", count: 3, seed: 127,
      negative_prompt: "Keep the original scene", guidance_scale: 4)
  }

  func testOpenBackAndUnknownChat() {
    let coordinator = AppCoordinator(window: UIWindow())
    coordinator.openChat(id: 2)
    XCTAssertNil(coordinator.currentChatID)
    coordinator.setAllowedChats([2, 3])
    coordinator.openChat(id: 2)
    XCTAssertEqual(coordinator.currentChatID, 2)
    coordinator.showChats()
    XCTAssertNil(coordinator.currentChatID)
    coordinator.openChat(id: 999)
    XCTAssertNil(coordinator.currentChatID)
    coordinator.close()
    XCTAssertNil(coordinator.currentChatID)
  }
  func testRepeatedRoundTripPreservesSelectedIdentity() {
    let coordinator = AppCoordinator(window: UIWindow())
    coordinator.openChat(id: 2)
    XCTAssertNil(coordinator.currentChatID)
    coordinator.setAllowedChats([2, 3])
    for step in 0..<100 {
      let id: ChatID = step.isMultiple(of: 2) ? 2 : 3
      coordinator.openChat(id: id)
      XCTAssertEqual(coordinator.currentChatID, id)
      coordinator.showChats()
      XCTAssertNil(coordinator.currentChatID)
    }
  }
}
