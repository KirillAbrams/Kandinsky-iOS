// Проверки входа в чат и возврата на айфоне. Они отдельно сверяют восстановление всех настроек
// запроса с фото и загрузку старого черновика без этих настроек.

import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class NavigationTests: XCTestCase {
  func testStartupRefusesADamagedDatabaseAndPreservesTheFile() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1", try NetworkCredentials.load() == nil
    else { throw XCTSkip("Нужна местная проверочная установка без сохранённого входа") }
    let fileManager = FileManager.default
    let support = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let appRoot = try AppDataRoot.resolve(support)
    let userID = Int64.random(in: 100_000...Int64.max)
    let root = appRoot.appendingPathComponent("net-v1-u\(userID)", isDirectory: true)
    guard !fileManager.fileExists(atPath: root.path) else { throw RepoError.io }
    defer { try? fileManager.removeItem(at: root) }
    let fixture = try await RepositoryHarness.open(root: root)
    try await fixture.close()
    let database = root.appendingPathComponent("chat.sqlite3")
    let previousBytes = try Data(contentsOf: database)
    var damaged = previousBytes
    damaged.replaceSubrange(0..<16, with: Data(repeating: 0x5A, count: 16))
    try damaged.write(to: database, options: .atomic)
    try NetworkCredentials.save(NetworkProfile(
      userId: userID, deviceId: UUID().uuidString, name: "Проверочный вход",
      token: String(repeating: "a", count: 64), expiresAtMs: .max))
    defer { try? NetworkCredentials.removeActive() }

    let window = UIWindow(frame: UIScreen.main.bounds)
    let coordinator = AppCoordinator(window: window)
    coordinator.start()
    let failure = (RepoError.corrupt as NSError).localizedDescription
    let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController?.view.subviews.compactMap { $0 as? UILabel }.contains {
        $0.text == failure && $0.numberOfLines == 3
      } == true
    }, object: nil)
    await fulfillment(of: [expected], timeout: 8)
    XCTAssertEqual(try Data(contentsOf: database), damaged)

    try previousBytes.write(to: database, options: .atomic)
    let recovered = try await RepositoryHarness.open(root: root)
    XCTAssertEqual(try recovered.rawScalar("SELECT unreadCount FROM chats WHERE id=2"), 3)
    try await recovered.close()
  }

  func testFailedDraftWriteLeavesAnInteractiveScreenAndAllowsAnotherAttempt() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1", let profile = try NetworkCredentials.load()
    else { throw XCTSkip("Нужен проверочный вход на местном сервере") }
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let accountRoot = try AppDataRoot.resolve(support)
      .appendingPathComponent("net-v1-u\(profile.userId)", isDirectory: true)
    let storage = try await SQLiteStore.open(root: accountRoot)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousWindow = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.makeKeyAndVisible()
    let coordinator = AppCoordinator(window: window)
    defer {
      if window.rootViewController != nil { coordinator.close() }
      window.isHidden = true
      previousWindow?.makeKey()
    }
    coordinator.start()
    let initialScreen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController?.view is ConversationChrome
        && window.rootViewController?.view.isUserInteractionEnabled == true
    }, object: nil)
    await fulfillment(of: [initialScreen], timeout: 12)
    if coordinator.currentChatID == nil {
      let chats = try await SQLiteChatRepository(store: storage).chats(matching: "")
      let chat = try XCTUnwrap(chats.first { !$0.archived })
      coordinator.setAllowedChats(Set(chats.map(\.id)))
      coordinator.openChat(id: chat.id)
      let chatReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        coordinator.currentChatID == chat.id
          && window.rootViewController?.view is ConversationChrome
          && window.rootViewController?.view.isUserInteractionEnabled == true
      }, object: nil)
      await fulfillment(of: [chatReady], timeout: 12)
    }
    _ = try XCTUnwrap(coordinator.currentChatID)
    let original = try XCTUnwrap(window.rootViewController)
    let saved = try await storage.perform { try StudioDraftStorage.load($0) }
    addTeardownBlock {
      try await storage.perform { db in
        try db.execute("DROP TRIGGER IF EXISTS coverage_draft_write_refused")
        if let saved {
          try StudioDraftStorage.write(db, saved)
        } else {
          try db.execute("DELETE FROM net_state WHERE key=?", [.text(StudioDraftStorage.key)])
        }
      }
      try await storage.close()
    }
    try await storage.perform { db in
      _ = try db.execute("""
        CREATE TRIGGER coverage_draft_write_refused BEFORE INSERT ON net_state
        WHEN NEW.key='studio.newDraft'
        BEGIN SELECT RAISE(ABORT,'coverage draft write refused'); END
        """)
    }
    coordinator.showChats()
    let recoveredControls = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let current = window.rootViewController, current !== original
      else { return false }
      return current.view is ConversationChrome && current.view.isUserInteractionEnabled
    }, object: nil)
    await fulfillment(of: [recoveredControls], timeout: 4)
    let afterFailure = try await storage.perform { try StudioDraftStorage.load($0) }
    XCTAssertEqual(afterFailure?.identity, saved?.identity)

    try await storage.perform { db in
      _ = try db.execute("DROP TRIGGER coverage_draft_write_refused")
    }
    let visible = try XCTUnwrap(window.rootViewController?.view as? ConversationChrome)
    let composer = try XCTUnwrap(visible.subviews.compactMap { $0 as? UITextView }.first {
      $0.accessibilityIdentifier == "composer.input"
    })
    let text = "Черновик после восстановления записи"
    composer.text = text
    composer.delegate?.textViewDidChange?(composer)
    coordinator.flush()
    var recovered: StudioDraftRecord?
    for _ in 0..<50 {
      recovered = try await storage.perform { try StudioDraftStorage.load($0) }
      if recovered?.draft.text == text { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(recovered?.draft.text, text)
    XCTAssertNotEqual(recovered?.identity, saved?.identity)
  }

  func testRefusedStartupInvitationLeavesTheAccountEntryAvailable() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1",
      try NetworkCredentials.load() == nil
    else { throw XCTSkip("Нужны местный сервер и проверочная установка без входа") }

    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    let coordinator = AppCoordinator(window: window)
    coordinator.start(invitation: String(repeating: "0", count: 64))
    let serverRefusal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController?.view.subviews.compactMap { $0 as? UILabel }.contains {
        $0.text == "Не удалось подключиться к Кандинскому (401)." && $0.numberOfLines == 3
      } == true
    }, object: nil)
    await fulfillment(of: [serverRefusal], timeout: 8)
    XCTAssertNil(try NetworkCredentials.load())

    coordinator.start()
    let entry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController is AccountEntryController
    }, object: nil)
    await fulfillment(of: [entry], timeout: 8)
    XCTAssertNil(try NetworkCredentials.load())
  }

  func testWarmInvitationLinkRestartsOnlyTheRecognizedHost() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1",
      ProcessInfo.processInfo.environment["KANDINSKY_TEST_WARM_LINK"] == "1",
      try NetworkCredentials.load() == nil
    else { throw XCTSkip("Нужен отдельный местный запуск без сохранённого входа") }

    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController is AccountEntryController
    }, object: nil)
    await fulfillment(of: [ready], timeout: 8)
    let original = try XCTUnwrap(window.rootViewController)
    let token = String(repeating: "0", count: 64)

    let wrong = try XCTUnwrap(URL(string: "kandinsky-native://other?invitation=" + token))
    let acceptedWrong = await UIApplication.shared.open(wrong)
    XCTAssertTrue(acceptedWrong)
    XCTAssertTrue(window.rootViewController === original)

    let invitation = try XCTUnwrap(URL(string: "kandinsky-native://join?invitation=" + token))
    let acceptedInvitation = await UIApplication.shared.open(invitation)
    XCTAssertTrue(acceptedInvitation)
    let rejected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      window.rootViewController?.view.subviews.compactMap { $0 as? UILabel }.contains {
        $0.text == "Не удалось подключиться к Кандинскому (401)."
      } == true
    }, object: nil)
    await fulfillment(of: [rejected], timeout: 8)
    XCTAssertFalse(window.rootViewController === original)
    XCTAssertNil(try NetworkCredentials.load())
  }

  // Сохраняем черновик с фото и выбранными настройками, закрываем и заново открываем настоящую
  // базу. Повторный экран должен получить весь прежний выбор.
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

  // Передаём черновик между экранами и сверяем полный набор параметров для фото. Восстановление
  // не должно ограничиться названием модели.
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

  // Читаем старый формат без настроек генерации. Текст, номер редакции и вложения сохраняются, а
  // настройки выбираются прежним запасным способом.
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

  // Проверяем открытие известного чата, возврат и запрос неизвестного номера. Несуществующая
  // история не должна остаться выбранной.
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

  func testStartingASecondChatRemovesTheFirstPendingNavigation() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Для быстрой смены истории нужны два чата на местном сервере")
    }
    let profile = try StudioTestServer.profile()
    let api = NetworkAPI(profile: profile)
    defer { api.close() }
    let long = try await StudioTestServer.chat("Длинная история", api: api)
    let media = try await StudioTestServer.chat("Плотная медиалента", api: api)
    XCTAssertNotEqual(long, media)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let coordinator = AppCoordinator(window: window)
    let oldSelection = NetworkCredentials.selectedChat(for: profile.userId)
    window.makeKeyAndVisible()
    coordinator.start()
    defer {
      coordinator.close()
      NetworkCredentials.selectChat(oldSelection, for: profile.userId)
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    let started = ProcessInfo.processInfo.systemUptime + 12
    while !(window.rootViewController?.view is ConversationChrome),
      ProcessInfo.processInfo.systemUptime < started
    { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(window.rootViewController?.view is ConversationChrome)
    let visible = window.rootViewController?.view
    coordinator.setAllowedChats([long, media])
    coordinator.openChat(id: long)
    let first = try XCTUnwrap(window.subviews.first { $0 is ConversationChrome && $0 !== visible })
    XCTAssertFalse(first.isUserInteractionEnabled)
    XCTAssertTrue(first.accessibilityElementsHidden)
    coordinator.openChat(id: media)
    XCTAssertNil(first.superview)
    let second = try XCTUnwrap(window.subviews.first { $0 is ConversationChrome && $0 !== visible })
    XCTAssertFalse(second === first)
    let finished = ProcessInfo.processInfo.systemUptime + 12
    while window.rootViewController?.view !== second, ProcessInfo.processInfo.systemUptime < finished {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(window.rootViewController?.view === second)
    XCTAssertEqual(coordinator.currentChatID, media)
    XCTAssertTrue(second.isUserInteractionEnabled)
    XCTAssertFalse(second.accessibilityElementsHidden)
    XCTAssertNil(first.superview)
  }

  // Повторяем вход и выход для разных чатов. После открытия выбран ровно нужный номер, а возврат
  // очищает текущий выбор.
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
