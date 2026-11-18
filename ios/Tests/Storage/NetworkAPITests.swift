import Foundation
import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class NetworkAPITests: XCTestCase {
  func testLostReadIsRetriedWhileAnUnansweredWriteIsSentOnlyOnce() async throws {
    let data = Data(#"{"chats":[]}"#.utf8)
    let api = makeAPI([
      .failure(.networkConnectionLost), .response(200, data), .failure(.timedOut),
    ])
    defer { api.close() }
    let recent = try await api.json("/v1/chats")
    XCTAssertEqual(recent, data)
    do {
      _ = try await api.json("/v1/kandinsky/activity", method: "POST")
      XCTFail("Ожидалась потеря ответа записи")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .timedOut)
    }
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/v1/chats", "/v1/chats", "/v1/kandinsky/activity",
    ])
  }

  func testAccountActionsSelectTheirOwnEndpointsAndDecodeTheReturnedProfile() async throws {
    let profile = testProfile()
    let data = try JSONEncoder().encode(profile)
    let api = makeAPI([
      .response(204, Data()), .response(202, Data()), .response(204, Data()),
      .response(200, data), .response(201, data), .response(201, data),
    ])
    defer { api.close() }
    let email = "fixture@example.test"
    let password = "isolated-fixture-password"
    try await api.requestEmailCode(email: email, recovery: false)
    try await api.requestEmailCode(email: email, recovery: true)
    try await api.resetPassword(email: email, code: "12345678", password: password)
    let signedIn = try await api.signIn(email: email, password: password)
    let registered = try await api.signIn(email: email, password: password, registrationCode: "12345678")
    let enrolled = try await api.enroll(invitation: String(repeating: "b", count: 64), name: "Проверка")
    XCTAssertEqual([signedIn.userId, registered.userId, enrolled.userId], [2, 2, 2])
    XCTAssertEqual(registered.username, profile.username)
    XCTAssertEqual(enrolled.deviceId, profile.deviceId)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/v1/demo/register/request", "/v1/demo/password-reset/request", "/v1/demo/password-reset/confirm",
      "/v1/demo/login", "/v1/demo/register", "/v1/devices/enroll",
    ])
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
  }

  func testBadPathsAndResponsesRespectTheSessionBoundary() async throws {
    let profile = testProfile()
    let expired = expectation(description: "Сигнал об отзыве сеанса")
    let api = makeAPI([
      .response(401, Data(#"{"error":{"code":"forbidden"}}"#.utf8)),
      .response(401, Data(#"{"error":{"code":"invalid_session"}}"#.utf8)),
      .response(200, Data(repeating: 32, count: 2 * 1024 * 1024 + 1)),
    ], profile: profile)
    defer { api.close() }
    api.onSessionRejected = { code in
      XCTAssertEqual(code, "invalid_session")
      expired.fulfill()
    }
    do {
      _ = try await api.json("/health")
      XCTFail("Адрес вне интерфейса приложения должен быть отклонён")
    } catch RepoError.invalidInput {}
    do {
      _ = try await api.enroll(invitation: "bad", name: "Проверка")
      XCTFail("Короткое приглашение должно быть отклонено")
    } catch RepoError.invalidInput {}
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)

    for code in ["forbidden", "invalid_session"] {
      do {
        _ = try await api.json("/v1/chats")
        XCTFail("Ожидался отказ сервера")
      } catch let failure as NetworkFailure {
        XCTAssertEqual(failure.status, 401)
        XCTAssertEqual(failure.code, code)
      }
    }
    await fulfillment(of: [expired], timeout: 3)
    do {
      _ = try await api.json("/v1/chats")
      XCTFail("Слишком большой ответ должен быть отклонён")
    } catch RepoError.io {}
    XCTAssertEqual(ScriptedHTTP.requests().map { $0.value(forHTTPHeaderField: "Authorization") },
                   Array(repeating: "Bearer " + profile.token, count: 3))
  }

  func testGenerationRetryKeepsItsIDUntilTheUpdatedRowIsSaved() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let job = UUID().uuidString.lowercased()
    let response = try generationResponse(job: job, running: true)
    let api = makeAPI([
      .failure(.networkConnectionLost), .response(200, response), .response(200, response),
    ], profile: profile)
    let local = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: profile.userId))
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: h.store, local: local, api: api)
    defer { sync.close() }
    let row = try await seedGeneration(sync, repository: repository, job: job)
    XCTAssertEqual(row.studioGeneration?.stage, .failed)
    let activeBefore = try await sync.activeGeneration(chat: 2)
    XCTAssertNil(activeBefore)
    let original = UUID()
    do {
      try await sync.generationAction(chat: 2, message: row.id, action: .retry, operation: original)
      XCTFail("Ожидалась потеря ответа")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .networkConnectionLost)
    }
    let retryRows = "SELECT count(*) FROM net_state WHERE key LIKE 'generationRetry:%'"
    XCTAssertEqual(try h.rawScalar(retryRows), 1)
    try await sync.generationAction(chat: 2, message: row.id, action: .retry, operation: UUID())
    XCTAssertEqual(try h.rawScalar(retryRows), 0)
    let activeAfter = try await sync.activeGeneration(chat: 2)
    XCTAssertEqual(activeAfter, row.id)
    let updated = try await repository.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(updated.map(\.id), [row.id])
    XCTAssertEqual(updated.first?.studioGeneration?.progress, 21)

    let slotID = UUID().uuidString.lowercased()
    let runID = UUID().uuidString.lowercased()
    let slot = StudioGeneration.Slot(
      id: slotID, status: .failed, blobId: nil, progress: nil, runId: runID)
    let slotRetry = UUID()
    try await sync.generationAction(
      chat: 2, message: row.id, action: .retry, operation: slotRetry, slot: slot)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST"])
    XCTAssertEqual(requests.map { $0.url?.path },
                   Array(repeating: "/v1/kandinsky/threads/2/generations/52/action", count: 3))
    let bodies = try requests.map(requestJSON)
    XCTAssertEqual(bodies, [
      ["action": "retry", "operation": original.uuidString.lowercased()],
      ["action": "retry", "operation": original.uuidString.lowercased()],
      ["action": "retry_slot", "operation": slotRetry.uuidString.lowercased(), "slot": slotID,
        "expected_run": runID],
    ])
    try await h.close()
  }

  func testGenerationContentAndReportActionsTargetTheResolvedServerRow() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = makeAPI(Array(repeating: .response(204, Data()), count: 3), profile: profile)
    let local = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: profile.userId))
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: h.store, local: local, api: api)
    defer { sync.close() }
    let row = try await seedGeneration(sync, repository: repository, job: UUID().uuidString.lowercased())
    do {
      try await sync.deleteGenerationContent(chat: 2, message: row.id, blob: "wrong")
      XCTFail("Ожидалось отклонение неверного номера файла")
    } catch RepoError.invalidInput {}
    do {
      try await sync.reportGeneration(chat: 12, message: row.id, reason: .inappropriate)
      XCTFail("Сообщение должно принадлежать указанному чату")
    } catch RepoError.notFound {}
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    let blob = String(repeating: "f", count: 32)
    try await sync.deleteGenerationContent(chat: 2, message: row.id, blob: blob)
    try await sync.deleteGenerationContent(chat: 2, message: row.id, blob: nil)
    try await sync.reportGeneration(chat: 2, message: row.id, reason: .inappropriate)
    let requests = ScriptedHTTP.requests()
    let path = "/v1/kandinsky/threads/2/generations/52"
    XCTAssertEqual(requests.map(\.httpMethod), ["DELETE", "DELETE", "POST"])
    XCTAssertEqual(requests.map { $0.url?.path }, [path, path, path + "/report"])
    XCTAssertEqual(requests.map { $0.url?.query }, ["target=result&blob=" + blob, "target=prompt", nil])
    XCTAssertEqual(try requestJSON(XCTUnwrap(requests.last)), ["reason": "inappropriate"])
    try await h.close()
  }

  func testRecentPhotoBecomesTheDraftReferenceWithoutASecondUpload() async throws {
    let h = try await RepositoryHarness.open()
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let photo = try Data(contentsOf: fixtures.appendingPathComponent("media/photo-000.jpg"))
    let blob = String(repeating: "3", count: 32)
    let recent = try JSONSerialization.data(withJSONObject: [
      "uploads": [["blobId": blob, "mime": "image/jpeg", "byteSize": photo.count]],
    ])
    let profile = testProfile()
    let api = makeAPI([.response(200, recent), .response(204, Data()), .response(200, photo)],
                      profile: profile)
    let local = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: profile.userId))
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: h.store, local: local, api: api)
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    let state = ConversationState(repository: repository)
    let chrome = ConversationChrome(chatID: 2, state: state, media: media, admission: admission, onBack: {})
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    chrome.frame = root.view.bounds
    root.view.addSubview(chrome)
    defer {
      root.dismiss(animated: false)
      chrome.persistAnchorAndClose()
      sync.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await h.store.perform { try NetworkSchema.install($0) }
    chrome.configureNetwork(sync)
    try await state.open(chatID: 2)
    try await chrome.openHistory(repository: repository, anchor: nil)
    chrome.restoreGenerationOptions(
      KandinskyOptions(model: "image", aspect: "3:5", count: 3, seed: 21))

    let plus = try XCTUnwrap(control("composer.plus", in: chrome))
    XCTAssertTrue(plus.isEnabled)
    plus.sendActions(for: .touchUpInside)
    let sheet = try XCTUnwrap(root.presentedViewController as? StudioGenerationSheet)
    for _ in 0..<250 {
      if !sheet.isBeingPresented && control("studio.recent." + blob, in: sheet.view) != nil { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let pick = try XCTUnwrap(control("studio.recent." + blob, in: sheet.view))
    pick.sendActions(for: .touchUpInside)
    for _ in 0..<250 {
      if !state.draft.attachmentDrafts.isEmpty { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await state.flush()
    let stored = try await repository.draft(chatID: 2)
    let reference = try XCTUnwrap(stored.attachmentDrafts.first)
    XCTAssertEqual(stored.attachmentDrafts.count, 1)
    XCTAssertEqual(reference.mime, "image/jpeg")
    XCTAssertEqual(try Data(contentsOf: media.fileURL(reference.relativePath)), photo)
    XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_uploads WHERE blobID='\(blob)'"), 1)
    XCTAssertEqual(chrome.generationOptions, KandinskyOptions(model: "video", aspect: "3:5", count: 3, seed: 21))
    let remove = try XCTUnwrap(control("studio.reference.remove", in: chrome))
    chrome.layoutIfNeeded()
    XCTAssertFalse(remove.superview?.isHidden ?? true)
    remove.sendActions(for: .touchUpInside)
    try await state.flush()
    let cleared = try await repository.draft(chatID: 2)
    XCTAssertTrue(cleared.attachmentDrafts.isEmpty)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/v1/kandinsky/uploads/recent", "/v1/kandinsky/threads/2/sources/" + blob, "/v1/media/" + blob,
    ])
    await state.close()
    try await h.close()
  }

  private func control(_ id: String, in view: UIView) -> UIControl? {
    if let control = view as? UIControl, control.accessibilityIdentifier == id { return control }
    return view.subviews.lazy.compactMap { self.control(id, in: $0) }.first
  }

  private func seedGeneration(
    _ sync: NetworkSync, repository: NetworkChatRepository, job: String
  ) async throws -> Message {
    let data = try generationResponse(job: job, running: false)
    try await sync.store.perform { [cache = sync.cache] db in
      try NetworkSchema.install(db)
      _ = try cache.generationRows(db, chat: 2, data: data)
    }
    let history = try await repository.history(PageRequest(chatID: 2))
    XCTAssertEqual(history.rows.count, 1)
    return try XCTUnwrap(history.rows.first)
  }

  private func generationResponse(job: String, running: Bool) throws -> Data {
    var metadata: [String: Any] = [
      "kandinskyJobId": job, "kandinskyStatus": running ? "running" : "failed",
      "kandinskyModel": "image", "kandinskyAspect": "1:1",
    ]
    if running { metadata["kandinskyProgress"] = 21 }
    return try JSONSerialization.data(withJSONObject: [
      "messages": [[
        "id": 52, "chatId": 2, "seq": 301, "senderId": 0, "clientId": job,
        "kind": "text", "text": running ? "Генерация" : "Не удалось создать", "caption": "",
        "savedAtMs": 1_794_483_289_395, "revision": running ? 2 : 1,
        "attachments": [], "metadata": metadata,
      ] as [String: Any]],
    ])
  }

  private func requestJSON(_ request: URLRequest) throws -> [String: String] {
    if let data = request.httpBody { return try JSONDecoder().decode([String: String].self, from: data) }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count == 0 { break }
      if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
      data.append(contentsOf: buffer.prefix(count))
    }
    return try JSONDecoder().decode([String: String].self, from: data)
  }

  private func testProfile() -> NetworkProfile {
    NetworkProfile(userId: 2, deviceId: "local-fixture", name: "Проверка",
                   token: String(repeating: "a", count: 64), expiresAtMs: Int64.max,
                   username: "fixture")
  }

  private func makeAPI(_ replies: [ScriptedHTTP.Reply], profile: NetworkProfile? = nil) -> NetworkAPI {
    ScriptedHTTP.configure(replies)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedHTTP.self]
    configuration.timeoutIntervalForRequest = 3
    return NetworkAPI(profile: profile, transportConfiguration: configuration)
  }
}

private final class ScriptedHTTP: URLProtocol, @unchecked Sendable {
  enum Reply {
    case response(Int, Data)
    case failure(URLError.Code)
  }

  private final class Script: @unchecked Sendable {
    let lock = NSLock()
    var received: [URLRequest] = []
    var replies: [Reply] = []
  }

  private static let script = Script()

  static func configure(_ replies: [Reply]) {
    script.lock.withLock {
      script.received.removeAll()
      script.replies = replies
    }
  }

  static func requests() -> [URLRequest] { script.lock.withLock { script.received } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let reply = Self.script.lock.withLock {
      Self.script.received.append(request)
      return Self.script.replies.isEmpty ? .failure(.badServerResponse) : Self.script.replies.removeFirst()
    }
    switch reply {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case let .response(status, data):
      guard let url = request.url,
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
