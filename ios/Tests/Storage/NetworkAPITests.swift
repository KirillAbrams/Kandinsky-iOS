// Проверяет сетевые запросы на заранее заданных ответах и временной базе. Так можно воспроизвести
// потерю связи и сверить порядок запросов без обращения к рабочему серверу.

import Foundation
import os
import CryptoKit
import UIKit
import XCTest

@testable import Kandinsky

@MainActor final class NetworkAPITests: XCTestCase {
  func testDownloadWritesOnlyTheMediaThatMatchesItsLengthAndDigest() async throws {
    let h = try await RepositoryHarness.open()
    let data = Data(repeating: 0x42, count: 140_000)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let altered = Data(repeating: 0x24, count: data.count)
    let api = ScriptedHTTP.makeAPI([
      .response(200, altered), .response(200, data), .response(404, Data()),
      .response(200, data),
    ], profile: testProfile())
    defer { api.close() }

    let original = h.root.appendingPathComponent("downloads/original")
    let unreachable = h.root.appendingPathComponent("downloads/unavailable")
    let tooLarge = h.root.appendingPathComponent("downloads/too-large")
    do {
      try await api.download(blob: digest, to: original, limit: Int64(data.count))
      XCTFail("Файл с изменёнными байтами не должен сохраняться")
    } catch RepoError.corrupt {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

    try await api.download(blob: digest, to: original, limit: Int64(data.count))
    XCTAssertEqual(try Data(contentsOf: original), data)
    try await api.download(blob: digest, to: original, limit: Int64(data.count))
    XCTAssertEqual(ScriptedHTTP.requests().count, 2)

    do {
      try await api.download(blob: digest, to: unreachable, limit: Int64(data.count))
      XCTFail("Ответ 404 не является файлом")
    } catch RepoError.io {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: unreachable.path))
    do {
      try await api.download(blob: digest, to: tooLarge, limit: Int64(data.count - 1))
      XCTFail("Файл больше допустимого размера не должен сохраняться")
    } catch RepoError.corrupt {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: tooLarge.path))
    XCTAssertEqual(ScriptedHTTP.requests().map { $0.url?.path }, Array(repeating: "/v1/media/" + digest, count: 4))
    try await h.close()
  }

  func testNativeDownloadPublishesProgressAndReusesTheFullOriginal() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Для проверки передачи нужен местный сервер")
    }
    let api = NetworkAPI(profile: try StudioTestServer.profile())
    defer { api.close() }
    let (_, page) = try await StudioTestServer.recentMedia(api)
    let assets = try WireObject(data: page).array("messages").flatMap {
      (try? WireObject($0).array("attachments")) ?? []
    }.map { try WireObject($0) }
    let video = try XCTUnwrap(assets.first {
      (try? $0.string("mime")) == "video/mp4" && ((try? $0.int("byteSize")) ?? 0) > 100_000
    })
    let blob = try video.string("blobId")
    let size = try video.int("byteSize")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("original.mp4")
    let downloaded = expectation(description: "Система сообщила о передаче всего ролика")
    let values = OSAllocatedUnfairLock(initialState: [Double]())
    try await api.download(blob: blob, to: file, limit: size) { value in
      values.withLock { $0.append(value) }
      if value == 1 { downloaded.fulfill() }
    }
    await fulfillment(of: [downloaded], timeout: 4)
    let progress = values.withLock { $0 }
    XCTAssertEqual(progress.first, 0)
    XCTAssertEqual(progress.last, 1)
    XCTAssertTrue(progress.contains { (0..<1).contains($0) && $0 > 0 })
    XCTAssertEqual(progress, progress.sorted())
    let original = try Data(contentsOf: file)
    XCTAssertEqual(Int64(original.count), size)
    try await api.download(blob: blob, to: file, limit: size) { _ in
      XCTFail("Повторное открытие готового файла не должно начинать передачу")
    }
    XCTAssertEqual(try Data(contentsOf: file), original)
  }

  func testUploadRejectsADirectoryBeforeSendingAnyRequest() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("source.jpg", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let api = ScriptedHTTP.makeAPI([], profile: testProfile())
    defer { api.close() }
    do {
      _ = try await api.upload(file: directory, mime: "image/jpeg", id: UUID().uuidString)
      XCTFail("Папка не должна отправляться как фото")
    } catch {
      XCTAssertFalse(error is NetworkFailure)
    }
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
  }

  // Подставляет обрыв чтения и потерянный ответ записи. Сравнивает адреса и порядок вызовов,
  // чтобы безопасное чтение повторилось, а запись сама не ушла второй раз.
  func testLostReadIsRetriedWhileAnUnansweredWriteIsSentOnlyOnce() async throws {
    let data = Data(#"{"chats":[]}"#.utf8)
    let api = ScriptedHTTP.makeAPI([
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

  // Вызывает отправку кодов, восстановление, вход, регистрацию и вход по приглашению. Сверяет
  // адреса, отсутствие старого ключа и данные профилей, полученных после успешного входа.
  func testAccountActionsSelectTheirOwnEndpointsAndDecodeTheReturnedProfile() async throws {
    let profile = testProfile()
    let data = try JSONEncoder().encode(profile)
    let api = ScriptedHTTP.makeAPI([
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

  // Проверяет отклонение чужого пути, короткого приглашения и чрезмерного ответа. Сверяет ключ
  // в отправленных запросах и ждёт отзыва входа только при соответствующем отказе сервера.
  func testAccountRemovalAcceptsLostConfirmationButRejectsAnInvalidPassword() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let refused = Data(#"{"error":{"code":"invalid_password"}}"#.utf8)
    let removed = Data(#"{"error":{"code":"account_deleted"}}"#.utf8)
    let api = ScriptedHTTP.makeAPI([
      .response(403, refused), .response(401, removed), .response(200, Data("{}".utf8)),
    ], profile: profile)
    let sync = NetworkSync(
      profile: profile, store: harness.store, local: SQLiteChatRepository(store: harness.store),
      api: api)
    defer { sync.close() }

    do {
      try await sync.eraseStudioAccount(password: "Неверный пароль")
      XCTFail("Ожидался отказ при неверном пароле")
    } catch let failure as NetworkFailure {
      XCTAssertEqual(failure.status, 403)
      XCTAssertEqual(failure.code, "invalid_password")
    }
    try await sync.eraseStudioAccount(password: "Проверочный пароль")
    try await sync.eraseStudioAccount(password: "Проверочный пароль")

    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), Array(repeating: "DELETE", count: 3))
    XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/v1/kandinsky/account", count: 3))
    XCTAssertEqual(try requests.map(requestJSON), [
      ["password": "Неверный пароль"], ["password": "Проверочный пароль"],
      ["password": "Проверочный пароль"],
    ])
    try await harness.close()
  }

  func testRevokedAndDeletedSessionsEachNotifyOnlyTheirOwnHandler() async throws {
    let harness = try await RepositoryHarness.open()
    let local = SQLiteChatRepository(store: harness.store)
    for (reason, expected) in [("invalid_session", "Истёк вход"), ("account_deleted", "Удалён аккаунт")] {
      let profile = testProfile()
      let api = ScriptedHTTP.makeAPI([], profile: profile)
      let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
      var changes: [String] = []
      sync.onSessionExpired = { changes.append("Истёк вход") }
      sync.onAccountErased = { changes.append("Удалён аккаунт") }

      sync.sessionRejected(reason)
      sync.sessionRejected("invalid_session")
      sync.sessionRejected("account_deleted")

      XCTAssertEqual(changes, [expected])
      XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
      sync.close()
    }
    try await harness.close()
  }

  func testRepeatedUserActionsSendOneActivityUpdateAndHandleARevokedSession() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let revoked = Data(#"{"error":{"code":"invalid_session"}}"#.utf8)
    let api = ScriptedHTTP.makeAPI([.response(401, revoked)], profile: profile)
    let sync = NetworkSync(
      profile: profile, store: harness.store, local: SQLiteChatRepository(store: harness.store),
      api: api)
    defer { sync.close() }
    let expired = expectation(description: "Телефон получил отзыв сеанса")
    expired.assertForOverFulfill = true
    sync.onSessionExpired = { expired.fulfill() }
    sync.onAccountErased = { XCTFail("Отзыв входа не удаляет аккаунт") }
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)

    sync.userInteraction()
    sync.userInteraction()
    sync.userInteraction()
    await fulfillment(of: [expired], timeout: 5)
    sync.userInteraction()

    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/kandinsky/activity"])
    XCTAssertEqual(requests.map(\.httpMethod), ["POST"])
    try await harness.close()
  }

  func testInitialConnectionLossRetriesWithoutClearingTheQueuedMessage() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    try await harness.store.perform { db in try NetworkSchema.install(db) }
    let operation = UUID().uuidString.lowercased()
    let appended = try await local.send(.init(operationID: operation, chatID: 2, text: "Ждёт сети"))
    let pendingID = try XCTUnwrap(appended.inserted.first?.id)
    let api = ScriptedHTTP.makeAPI([
      .failure(.notConnectedToInternet), .failure(.notConnectedToInternet),
    ], profile: profile)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    let failures = expectation(description: "Первое подключение и его повтор завершились отказом")
    failures.expectedFulfillmentCount = 2
    let afterBackground = expectation(description: "В фоне не начинается ещё одно подключение")
    afterBackground.isInverted = true
    var epochs: [Int] = []
    var connectionCount = 0
    sync.onStatus = { value in
      if value == "Подключение…" {
        connectionCount += 1
        if connectionCount > 2 { afterBackground.fulfill() }
      } else if value == "Нет связи · сообщения сохранены" {
        epochs.append(sync.connectionEpoch)
        if epochs.count == 2 { sync.foreground(false) }
        failures.fulfill()
      }
    }
    sync.foreground(true)
    await fulfillment(of: [failures], timeout: 5)
    let firstEpoch = try XCTUnwrap(epochs.first)
    let secondEpoch = try XCTUnwrap(epochs.last)
    XCTAssertGreaterThan(secondEpoch, firstEpoch)
    XCTAssertFalse(sync.active)
    await fulfillment(of: [afterBackground], timeout: 1.5)
    XCTAssertEqual(connectionCount, 2)
    XCTAssertEqual(ScriptedHTTP.requests().map { $0.url?.path }, ["/v1/bootstrap", "/v1/bootstrap"])
    let history = try await local.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(history.map(\.id), [pendingID])
    XCTAssertEqual(history.first?.delivery, .pending)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE errorCode IS NULL"), 1)
    try await harness.close()
  }

  func testRejectedBootstrapStopsInsteadOfRetryingWithTheExpiredToken() async throws {
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { db in try NetworkSchema.install(db) }
    let profile = testProfile()
    // У сетевого шлюза может быть другое тело ответа. Любой отказ 401 требует повторного входа.
    for reply in [#"{"error":{"code":"invalid_session"}}"#, #"{"error":"Unauthorized"}"#] {
      let api = ScriptedHTTP.makeAPI([.response(401, Data(reply.utf8))], profile: profile)
      let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
      defer { sync.close() }
      let expired = expectation(description: "Ответ 401 отключил сетевой сеанс")
      expired.assertForOverFulfill = true
      var statuses: [String] = []
      sync.onSessionExpired = { expired.fulfill() }
      sync.onAccountErased = { XCTFail("Отказ при входе не означает удаления аккаунта") }
      sync.onStatus = { statuses.append($0) }
      sync.foreground(true)
      await fulfillment(of: [expired], timeout: 5)
      XCTAssertFalse(sync.active)
      XCTAssertFalse(sync.resumed)
      XCTAssertEqual(statuses, ["Подключение…"])
      XCTAssertEqual(ScriptedHTTP.requests().map { $0.url?.path }, ["/v1/bootstrap"])
    }
    try await harness.close()
  }

  func testACommittedSendWithoutItsAcknowledgementIsRetriedWithTheSameID() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1",
      let configured = ProcessInfo.processInfo.environment["KANDINSKY_TEST_DROP_ACK_OPERATION"],
      let operation = UUID(uuidString: configured)
    else { throw XCTSkip("Нужен местный стенд, который пропустит одно подтверждение") }
    let profile = try StudioTestServer.profile()
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { db in try NetworkSchema.install(db) }
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: harness.store, local: local)
    defer { sync.close() }
    let created = try await sync.createStudioThread(id: UUID())
    let connected = expectation(description: "Установлено первое соединение")
    let missed = expectation(description: "Истёк срок ожидания подтверждения отправки")
    let reconnected = expectation(description: "После потери ответа установлен новый канал")
    let accepted = expectation(description: "Повтор подтверждён и записан местно")
    var connections = 0
    sync.onStatus = { status in
      if status == "В сети" {
        connections += 1
        if connections == 1 { connected.fulfill() }
        if connections == 2 { reconnected.fulfill() }
      } else if status == "Нет связи · сообщения сохранены" {
        missed.fulfill()
      }
    }
    sync.foreground(true)
    await fulfillment(of: [connected], timeout: 10)

    do {
      let prompt = "AckQA-" + operation.uuidString.prefix(8)
      let delta = try await local.send(.init(
        operationID: operation.uuidString, chatID: created, text: prompt,
        generationOptions: KandinskyOptions(model: "image", count: 1)))
      let message = try XCTUnwrap(delta.inserted.first)
      sync.onDeltas = { updates in
        if updates.flatMap({ $0.inserted + $0.updated }).contains(where: {
          $0.id == message.id && $0.delivery == .accepted
        }) { accepted.fulfill() }
      }
      XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox"), 1)
      sync.kick()
      await fulfillment(of: [missed, reconnected, accepted], timeout: 23)
      XCTAssertEqual(connections, 2)
      XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox"), 0)
      let cached = try await local.history(PageRequest(chatID: created)).rows
      XCTAssertEqual(cached.filter { $0.text == prompt }.map(\.id), [message.id])
      let data = try await sync.api.json("/v1/chats/\(created)/history?limit=16")
      let serverRows = try WireObject(data: data).array("messages").map { try WireObject($0) }
      XCTAssertEqual(try serverRows.filter {
        try $0.string("kind") == "text" && $0.string("text") == prompt
      }.count, 1)
    } catch {
      try? await sync.deleteStudioThread(created)
      try? await harness.close()
      throw error
    }
    try await sync.deleteStudioThread(created)
    sync.foreground(false)
    try await harness.close()
  }

  func testUnreadableOutboxPayloadKeepsTheRequestAndSendsItOnceRestored() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Для отказа очереди нужен отдельный местный сервер")
    }
    let harness = try await RepositoryHarness.open()
    let profile = try StudioTestServer.profile()
    try await harness.store.perform { try NetworkSchema.install($0) }
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: harness.store, local: local)
    let chat = try await sync.createStudioThread(id: UUID())
    addTeardownBlock { @MainActor in
      sync.foreground(false)
      defer { sync.close() }
      try await sync.deleteStudioThread(chat)
      try await harness.close()
    }

    let firstConnection = expectation(description: "Очередь подключилась к серверу")
    let refused = expectation(description: "Ошибка чтения оставила запрос на устройстве")
    let regained = expectation(description: "После ошибки связь восстановилась")
    var connections = 0
    var reportedFailure = false
    sync.onStatus = { status in
      if status == "В сети" {
        connections += 1
        if connections == 1 { firstConnection.fulfill() }
        if connections == 2 { regained.fulfill() }
      } else if status == "Нет связи · сообщения сохранены", !reportedFailure {
        reportedFailure = true
        refused.fulfill()
      }
    }
    sync.foreground(true)
    await fulfillment(of: [firstConnection], timeout: 10)
    let operation = UUID().uuidString.lowercased()
    let prompt = "Локальное ожидание " + operation.prefix(8)
    let result = try await local.send(.init(operationID: operation, chatID: chat, text: prompt))
    let message = try XCTUnwrap(result.inserted.first)
    let accepted = expectation(description: "Исходная команда подтверждена и записана в историю")
    sync.onDeltas = { deltas in
      if deltas.flatMap({ $0.inserted + $0.updated }).contains(where: {
        $0.id == message.id && $0.delivery == .accepted
      }) {
        accepted.fulfill()
      }
    }
    let payload = try await harness.store.perform { db in
      let value = try XCTUnwrap(
        db.rows("SELECT payload FROM net_outbox WHERE id=?", [.text(operation)]).first?["payload"])
      try db.execute("UPDATE net_outbox SET payload='{' WHERE id=?", [.text(operation)])
      return value
    }
    sync.kick()
    await fulfillment(of: [refused], timeout: 8)
    let pending = try await local.history(PageRequest(chatID: chat))
    XCTAssertEqual(pending.rows.filter { $0.text == prompt }.map(\.id), [message.id])
    XCTAssertEqual(pending.rows.first { $0.id == message.id }?.delivery, .pending)
    try await harness.store.perform { db in
      _ = try db.execute("UPDATE net_outbox SET payload=? WHERE id=?", [payload, .text(operation)])
    }
    await fulfillment(of: [regained, accepted], timeout: 10)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox"), 0)
    let serverData = try await sync.api.json("/v1/chats/\(chat)/history?limit=8")
    let serverRows = try WireObject(data: serverData).array("messages").map { try WireObject($0) }
    XCTAssertEqual(try serverRows.filter { try $0.string("text") == prompt }.count, 1)
  }

  func testOversizedSocketMessageIsRejectedByByteCountWithoutClosingTheConnection() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Для проверки ограничения нужен местный сервер")
    }
    let profile = try StudioTestServer.profile()
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo)
    defer { sync.close() }
    let connected = expectation(description: "Служба подтвердила подключение")
    sync.onStatus = { if $0 == "В сети" { connected.fulfill() } }
    sync.foreground(true)
    await fulfillment(of: [connected], timeout: 12)
    XCTAssertTrue(sync.resumed)
    let text = String(repeating: "я", count: 33_000)
    XCTAssertLessThan(text.count, 65_536)
    XCTAssertGreaterThan(text.utf8.count, 65_536)
    do {
      try await sync.send(["type": "ping", "data": text])
      XCTFail("Пакет сверх ограничения по байтам не должен быть отправлен")
    } catch RepoError.invalidInput {}
    XCTAssertTrue(sync.resumed)
    try await sync.send(["type": "ping"])
    sync.foreground(false)
    try await harness.close()
  }

  func testRefusedSourceMarksOnlyItsRequestFailedAndTheQueueStillSends() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1",
      ProcessInfo.processInfo.environment["KANDINSKY_TEST_SOURCE_GATE"] == "1"
    else { throw XCTSkip("Нужен местный сервер с управляемым отказом передачи") }
    let h = try await RepositoryHarness.open()
    let profile = try StudioTestServer.profile()
    let local = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: h.store, local: local)
    let media = MediaStore(store: h.store)
    defer {
      media.close()
      sync.close()
    }
    try await h.store.perform { try NetworkSchema.install($0) }
    let chat = try await sync.createStudioThread(id: UUID())
    do {
      let fixtures = try XCTUnwrap(
        Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
      let attachment = try await media.stageStudioPhoto(
        sourceURL: fixtures.appendingPathComponent("media/photo-000.jpg"))
      let firstID = UUID().uuidString.lowercased()
      let failed = try await local.send(SendCommand(
        operationID: firstID, chatID: chat, text: "Задание с отклонённым исходником",
        attachments: [attachment], generationOptions: .init(model: "video")))
      let failedID = try XCTUnwrap(failed.inserted.first?.id)
      let decision = "/v1/__coverage/source/" + attachment.id.lowercased()
      _ = try await sync.api.json(decision + "/reject", method: "PUT")
      let refused = expectation(description: "В очереди отмечен отказ конкретного исходника")
      sync.onStatus = {
        if $0 == "Не отправлено: local_test_source_refused" { refused.fulfill() }
      }
      sync.foreground(true)
      await fulfillment(of: [refused], timeout: 12)
      let refusedState = try WireObject(data: await sync.api.json(decision)).string("state")
      XCTAssertEqual(refusedState, "rejected")
      let afterRefusal = try await local.history(PageRequest(chatID: chat))
      XCTAssertEqual(afterRefusal.rows.first { $0.id == failedID }?.delivery, .failed)
      XCTAssertEqual(try h.rawScalar(
        "SELECT count(*) FROM net_outbox WHERE errorCode='local_test_source_refused'"), 1)
      XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_uploads"), 0)

      let secondID = UUID().uuidString.lowercased()
      _ = try await local.send(SendCommand(operationID: secondID, chatID: chat, text: "Следующий запрос"))
      sync.kick()
      let waiting = "SELECT count(*) FROM net_outbox WHERE id='\(secondID)'"
      for _ in 0..<180 {
        if try h.rawScalar(waiting) == 0 { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(try h.rawScalar(waiting), 0)
      XCTAssertEqual(try h.rawScalar(
        "SELECT count(*) FROM net_messages WHERE clientID='\(secondID)' AND serverID IS NOT NULL"), 1)
      XCTAssertEqual(try h.rawScalar(
        "SELECT count(*) FROM net_outbox WHERE id='\(firstID)' AND errorCode IS NOT NULL"), 1)
    } catch {
      sync.foreground(false)
      try? await sync.deleteStudioThread(chat)
      try? await h.close()
      throw error
    }
    sync.foreground(false)
    try await sync.deleteStudioThread(chat)
    try await h.close()
  }

  func testLegacyDeletionRefusalRemovesTheCommandAndDoesNotBlockSending() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1" else {
      throw XCTSkip("Для проверки очереди нужен местный сервер")
    }
    let h = try await RepositoryHarness.open()
    let profile = try StudioTestServer.profile()
    let local = SQLiteChatRepository(store: h.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: h.store, local: local)
    defer { sync.close() }
    try await h.store.perform { try NetworkSchema.install($0) }
    let chat = try await sync.createStudioThread(id: UUID())

    func accepted(_ id: String) async throws -> Bool {
      let query = "SELECT count(*) FROM net_messages WHERE clientID='\(id)' AND serverID IS NOT NULL"
      for _ in 0..<160 {
        if try h.rawScalar(query) == 1 { return true }
        try await Task.sleep(for: .milliseconds(50))
      }
      return false
    }

    do {
      let firstID = UUID().uuidString.lowercased()
      let first = try await local.send(
        SendCommand(operationID: firstID, chatID: chat, text: "Исходный запрос"))
      let deletedID = try XCTUnwrap(first.inserted.first?.id)
      sync.foreground(true)
      let firstConfirmed = try await accepted(firstID)
      XCTAssertTrue(firstConfirmed)

      let refused = expectation(description: "Сервер отклонил старую команду удаления")
      sync.onStatus = {
        if $0 == "Не отправлено: Используйте отмену генерации" { refused.fulfill() }
      }
      let deletion = try await local.delete(messageID: deletedID)
      XCTAssertEqual(deletion.removedIDs, [deletedID])
      sync.kick()
      await fulfillment(of: [refused], timeout: 8)
      XCTAssertEqual(try h.rawScalar(
        "SELECT count(*) FROM net_outbox WHERE action='delete'"), 0)

      let secondID = UUID().uuidString.lowercased()
      _ = try await local.send(SendCommand(
        operationID: secondID, chatID: chat, text: "Запрос после отказа удаления"))
      sync.kick()
      let secondConfirmed = try await accepted(secondID)
      XCTAssertTrue(secondConfirmed)
      XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_outbox WHERE errorCode IS NULL"), 0)
    } catch {
      sync.foreground(false)
      try? await sync.deleteStudioThread(chat)
      try? await h.close()
      throw error
    }
    sync.foreground(false)
    try await sync.deleteStudioThread(chat)
    try await h.close()
  }

  func testBadPathsAndResponsesRespectTheSessionBoundary() async throws {
    let profile = testProfile()
    let expired = expectation(description: "Сигнал об отзыве сеанса")
    let api = ScriptedHTTP.makeAPI([
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

  // Имитирует потерянный ответ при повторе генерации и сверяет номер в базе и повторных запросах.
  // После сохранения обновлённой строки старый номер убирается, а отдельный повтор файла несёт
  // номер прежнего запуска.
  func testGenerationRetryKeepsItsIDUntilTheUpdatedRowIsSaved() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let job = UUID().uuidString.lowercased()
    let response = try generationResponse(job: job, running: true)
    let api = ScriptedHTTP.makeAPI([
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

  // Проверяет отклонение чужого чата и неподходящего вложения до запроса. Сверяет, что удаление
  // результата, удаление текста и жалоба адресованы нужной серверной строке.
  func testGenerationContentAndReportActionsTargetTheResolvedServerRow() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI(Array(repeating: .response(204, Data()), count: 3), profile: profile)
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

  func testHistoryActionsReportAndRemoveTheSelectedServerResult() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([.response(204, Data()), .response(204, Data())], profile: profile)
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    let blob = String(repeating: "d", count: 32)
    try await seedHistoryChat(sync)
    let result: [String: Any] = [
      "id": 52, "chatId": 2, "seq": 52, "senderId": 0, "clientId": UUID().uuidString.lowercased(),
      "kind": "photo", "text": "", "caption": "", "savedAtMs": 1000, "revision": 1,
      "attachments": [[
        "id": "first-result", "blobId": blob, "mime": "image/jpeg",
        "byteSize": 300, "rawWidth": 20, "rawHeight": 20, "orientation": 1, "thumbnailKey": blob,
      ]],
    ]
    let payload = try JSONSerialization.data(withJSONObject: ["messages": [result], "hasOlder": false])
    try await harness.store.perform { [cache = sync.cache] db in
      _ = try cache.history(db, chat: 2, data: payload)
    }
    let page = try await repository.history(PageRequest(chatID: 2))
    let nativeResult = try XCTUnwrap(page.rows.first)
    let state = ConversationState(repository: repository)
    try await state.open(chatID: 2)

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    let chrome = ConversationChrome(chatID: 2, state: state, onBack: {})
    host.view = chrome
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      chrome.persistAnchorAndClose()
      sync.close()
      host.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKey()
    }
    chrome.layoutIfNeeded()
    chrome.configureNetwork(sync)
    try await chrome.openHistory(repository: repository, anchor: nil)
    let timeline = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChatScrollHost }.first)
    let showMenu = try XCTUnwrap(timeline.onMessageLongPress)
    showMenu(nativeResult, .zero)
    let actions = try XCTUnwrap(host.presentedViewController as? KandinskyActionSheet)
    let appeared = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !actions.isBeingPresented }, object: nil)
    await fulfillment(of: [appeared], timeout: 3)
    try XCTUnwrap(control("actions.1", in: actions.view)).sendActions(for: .touchUpInside)
    let reported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (host.presentedViewController as? UIAlertController)?.title == "Жалоба отправлена"
    }, object: nil)
    await fulfillment(of: [reported], timeout: 5)

    let removeResult = try XCTUnwrap(timeline.onStudioResultDelete)
    removeResult(nativeResult.id, blob)
    let removed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in ScriptedHTTP.requests().count == 2 }, object: nil)
    await fulfillment(of: [removed], timeout: 5)
    let requests = ScriptedHTTP.requests()
    let generation = "/v1/kandinsky/threads/2/generations/52"
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
    XCTAssertEqual(requests.map { $0.url?.path }, [generation + "/report", generation])
    XCTAssertEqual(try requestJSON(XCTUnwrap(requests.first)), ["reason": "harmful"])
    XCTAssertEqual(requests.last?.url?.query, "target=result&blob=" + blob)
    await state.close()
    try await harness.close()
  }

  func testHistoryAccessibilityRetriesOnlyTheSelectedGenerationSlot() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let job = UUID().uuidString.lowercased()
    let oldRun = UUID().uuidString.lowercased()
    let newRun = UUID().uuidString.lowercased()
    let failed = StudioGeneration.Slot(
      id: UUID().uuidString.lowercased(), status: .failed, blobId: nil, progress: nil, runId: oldRun)
    let blocked = StudioGeneration.Slot(
      id: UUID().uuidString.lowercased(), status: .failed, blobId: nil, progress: nil, moderated: true)
    let running = StudioGeneration.Slot(
      id: failed.id, status: .running, blobId: nil, progress: 21, runId: newRun)
    let response = try generationResponse(job: job, running: true, slots: [running, blocked])
    let api = ScriptedHTTP.makeAPI([.response(200, response)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await seedHistoryChat(sync)
    let original = try generationResponse(job: job, running: false, slots: [failed, blocked])
    try await harness.store.perform { [cache = sync.cache] database in
      _ = try cache.generationRows(database, chat: 2, data: original)
    }
    let page = try await repository.history(PageRequest(chatID: 2))
    let row = try XCTUnwrap(page.rows.first)
    XCTAssertEqual(row.studioGeneration?.slots?.first?.runId, oldRun)
    let state = ConversationState(repository: repository)
    try await state.open(chatID: 2)
    let chrome = ConversationChrome(chatID: 2, state: state, onBack: {})
    defer { chrome.persistAnchorAndClose() }
    chrome.configureNetwork(sync)
    try await chrome.openHistory(repository: repository, anchor: nil)
    let timeline = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ChatScrollHost }.first)
    timeline.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    // Окно здесь не показано. Даём ленте строку из прочитанной страницы, как после её появления.
    timeline.loaded[row.id] = row
    let layout = PreparedText(message: row, key: timeline.key(row))
    timeline.cache.insert(layout)
    var elements: [Any] = []
    timeline.appendRowAccessibility(row, layout: layout, x: 16, rowY: 30, viewY: 30, elements: &elements)
    let buttons = elements.compactMap { $0 as? UIAccessibilityElement }
    func element(for slot: StudioGeneration.Slot) throws -> UIAccessibilityElement {
      try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "generation.slot.\(row.id).\(slot.id)" })
    }
    XCTAssertFalse(try element(for: blocked).accessibilityActivate())
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    let active = expectation(description: "Новый запуск выбранного результата сохранён")
    sync.onDeltas = { _ in active.fulfill() }
    final class PositionedTap: UITapGestureRecognizer {
      var point = CGPoint.zero
      override func location(in view: UIView?) -> CGPoint { point }
    }
    let failedCell = try XCTUnwrap(layout.generationCard?.retryCells.first { $0.slot.id == failed.id })
    let top = try XCTUnwrap(timeline.index.top(of: row.id))
    let tap = PositionedTap(target: nil, action: nil)
    tap.point = CGPoint(x: timeline.rowLeft(row, layout) + failedCell.frame.midX,
      y: CGFloat(top) + failedCell.frame.midY)
    let retry = try XCTUnwrap(timeline.onStudioRetrySlot)
    var activated: [String] = []
    timeline.onStudioRetrySlot = { message, slot in
      activated.append(slot.id)
      retry(message, slot)
    }
    XCTAssertEqual(timeline.index.anchorAt(offset: Double(tap.point.y)).messageID, row.id)
    timeline.tapped(tap)
    XCTAssertEqual(activated, [failed.id])
    // Нажатие той же кнопки через озвучивание до ответа не должно создавать ещё один запуск.
    XCTAssertTrue(try element(for: failed).accessibilityActivate())
    XCTAssertEqual(activated, [failed.id, failed.id])
    await fulfillment(of: [active], timeout: 5)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/v1/kandinsky/threads/2/generations/52/action")
    let payload = try requestJSON(request)
    XCTAssertEqual(payload["action"], "retry_slot")
    XCTAssertEqual(payload["slot"], failed.id)
    XCTAssertEqual(payload["expected_run"], oldRun)
    XCTAssertNotNil(payload["operation"].flatMap(UUID.init(uuidString:)))
    let updated = try await repository.history(PageRequest(chatID: 2))
    XCTAssertEqual(updated.rows.first?.studioGeneration?.slots?.first?.runId, newRun)
    await state.close()
    try await harness.close()
  }

  // Выбирает недавний снимок как исходник, сверяет сохранённые байты и отсутствие второй записи
  // загрузки. Дополнительно проверяет настройки генерации и удаление исходника из черновика.
  func testRecentPhotoBecomesTheDraftReferenceWithoutASecondUpload() async throws {
    let h = try await RepositoryHarness.open()
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let photo = try Data(contentsOf: fixtures.appendingPathComponent("media/photo-000.jpg"))
    let blob = String(repeating: "3", count: 32)
    let corruptBlob = String(repeating: "5", count: 32)
    let corrupt = Data("Непригодные байты изображения".utf8)
    let recent = try JSONSerialization.data(withJSONObject: [
      "uploads": [
        ["blobId": blob, "mime": "image/jpeg", "byteSize": photo.count],
        ["blobId": corruptBlob, "mime": "image/jpeg", "byteSize": corrupt.count],
      ],
    ])
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([
      .response(200, recent), .response(204, Data()), .response(200, photo),
      .response(200, recent), .response(204, Data()), .response(200, corrupt),
    ], profile: profile)
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
    func chooseRecent(_ id: String) async throws {
      XCTAssertTrue(plus.isEnabled)
      plus.sendActions(for: .touchUpInside)
      let sheet = try XCTUnwrap(root.presentedViewController as? StudioGenerationSheet)
      let controlID = "studio.recent." + id
      for _ in 0..<250 {
        if !sheet.isBeingPresented && control(controlID, in: sheet.view) != nil { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      try XCTUnwrap(control(controlID, in: sheet.view)).sendActions(for: .touchUpInside)
    }
    try await chooseRecent(blob)
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
    try await chooseRecent(corruptBlob)
    func fileError() -> UILabel? {
      chrome.subviews.flatMap(\.subviews).compactMap { $0 as? UILabel }.first {
        $0.accessibilityIdentifier == "studio.attachment.error"
      }
    }
    let refused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      fileError()?.text == "Не удалось открыть файл"
    }, object: nil)
    await fulfillment(of: [refused], timeout: 5)
    let afterFailure = try await repository.draft(chatID: 2)
    XCTAssertEqual(afterFailure.attachmentDrafts.map(\.id), [reference.id])
    XCTAssertEqual(try Data(contentsOf: media.fileURL(reference.relativePath)), photo)
    XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_uploads WHERE blobID='\(corruptBlob)'"), 0)

    let remove = try XCTUnwrap(control("studio.reference.remove", in: chrome))
    chrome.layoutIfNeeded()
    XCTAssertFalse(remove.superview?.isHidden ?? true)
    remove.sendActions(for: .touchUpInside)
    try await state.flush()
    let cleared = try await repository.draft(chatID: 2)
    XCTAssertTrue(cleared.attachmentDrafts.isEmpty)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "GET", "POST", "GET"])
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/v1/kandinsky/uploads/recent", "/v1/kandinsky/threads/2/sources/" + blob, "/v1/media/" + blob,
      "/v1/kandinsky/uploads/recent", "/v1/kandinsky/threads/2/sources/" + corruptBlob,
      "/v1/media/" + corruptBlob,
    ])
    let dismissedError = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      fileError() == nil
    }, object: nil)
    await fulfillment(of: [dismissedError], timeout: 6)
    await state.close()
    try await h.close()
  }

  func testRecentVideoCanBecomeAnEnhancementReferenceWithoutUploadingItAgain() async throws {
    let h = try await RepositoryHarness.open()
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let video = try Data(contentsOf: fixtures.appendingPathComponent("media/video-01.mp4"))
    let blob = String(repeating: "7", count: 32)
    let recent = try JSONSerialization.data(withJSONObject: [
      "uploads": [["blobId": blob, "mime": "video/mp4", "byteSize": video.count]],
    ])
    let models = Data(
      #"{"models":[{"id":"video_sr","name":"Улучшение видео","description":"Увеличение размера"}]}"#.utf8)
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([
      .response(200, recent), .response(204, Data()), .response(200, video), .response(200, models),
    ], profile: profile)
    let sync = NetworkSync(profile: profile, store: h.store, local: h.repo, api: api)
    let media = MediaStore(store: h.store)
    let admission = MediaAdmission()
    try await h.store.perform { try NetworkSchema.install($0) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    let state = ConversationState(repository: h.repo)
    try await state.open(chatID: 2)
    var options = KandinskyOptions(model: "image")
    let presented = expectation(description: "Короткий ролик доступен для улучшения")
    var useVideo: (() -> Void)?
    let coordinator = ChatAttachmentCoordinator(
      view: parent.view, state: state, media: media, admission: admission,
      presenter: { parent }, options: { options },
      selectOptions: { options = $0 },
      showError: { XCTFail($0) },
      previewVideo: { attachment, enhance, _ in
        XCTAssertEqual(attachment.mime, "video/mp4")
        XCTAssertEqual(attachment.durationMs, 2000)
        useVideo = enhance
        presented.fulfill()
      },
      showProgress: { _ in })
    coordinator.network = sync
    defer {
      coordinator.close(discardDraft: false)
      parent.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKey()
      media.close()
      admission.close()
      sync.close()
    }

    coordinator.showPicker()
    let sheet = try XCTUnwrap(parent.presentedViewController as? StudioGenerationSheet)
    let reference = "studio.recent." + blob
    for _ in 0..<150 {
      if !sheet.isBeingPresented && control(reference, in: sheet.view) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try XCTUnwrap(control(reference, in: sheet.view)).sendActions(for: .touchUpInside)
    await fulfillment(of: [presented], timeout: 6)
    XCTAssertTrue(state.draft.attachmentDrafts.isEmpty)
    let selected = expectation(description: "Ролик стал исходником с моделью улучшения")
    state.onChange = {
      if !coordinator.isImporting, state.draft.attachmentDrafts.first?.mime == "video/mp4" {
        state.onChange = nil
        selected.fulfill()
      }
    }
    try XCTUnwrap(useVideo)()
    await fulfillment(of: [selected], timeout: 6)
    state.onChange = nil
    try await state.flush()
    let stored = try await h.repo.draft(chatID: 2)
    let source = try XCTUnwrap(stored.attachmentDrafts.first)
    XCTAssertEqual(stored.generationOptions?.model, "video_sr")
    XCTAssertEqual(options.model, "video_sr")
    XCTAssertEqual(try Data(contentsOf: media.fileURL(source.relativePath)), video)
    XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_uploads WHERE blobID='\(blob)'"), 1)
    XCTAssertEqual(ScriptedHTTP.requests().map(\.httpMethod), ["GET", "POST", "GET", "GET"])
    await state.close()
    try await h.close()
  }

  func testRestoredAttachmentKeepsTheComposerModelCompatibleWithItsFile() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
    let media = MediaStore(store: harness.store)
    let admission = MediaAdmission()
    let state = ConversationState(repository: harness.repo)
    let composer = ConversationChrome(
      chatID: 0, state: state, media: media, admission: admission, onBack: {})
    composer.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    composer.configureNetwork(sync)
    defer {
      composer.persistAnchorAndClose()
      sync.close()
      media.close()
      admission.close()
    }
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let video = try await media.stageSelection(
      sourceURL: fixtures.appendingPathComponent("real-media/backend-990da02cd31e46cfb8fd630c293f3489.mp4"),
      mime: "video/mp4")
    let photo = try await media.stageSelection(
      sourceURL: fixtures.appendingPathComponent("real-media/backend-824d66cce0d64409ad4888a13792c7d4.jpg"),
      mime: "image/jpeg")
    var draft = Draft(text: "Восстановленный запрос")
    draft.attachmentDrafts = [video]
    draft.generationOptions = KandinskyOptions(model: "image")
    let send = try XCTUnwrap(control("composer.send", in: composer))
    let remove = try XCTUnwrap(control("studio.reference.remove", in: composer))
    var models: [String] = []
    composer.onFirstSend = { models.append($0.model) }
    composer.openStudioDraft(draft)
    composer.layoutIfNeeded()
    XCTAssertTrue(send.isEnabled)
    XCTAssertEqual(remove.accessibilityLabel, "Удалить исходное видео")
    send.sendActions(for: .touchUpInside)

    draft.generationOptions = KandinskyOptions(model: "video_sr")
    draft.attachmentDrafts = []
    state.editDraft(draft)
    send.sendActions(for: .touchUpInside)
    draft.attachmentDrafts = [photo]
    state.editDraft(draft)
    composer.layoutIfNeeded()
    XCTAssertEqual(remove.accessibilityLabel, "Удалить исходное фото")
    send.sendActions(for: .touchUpInside)

    XCTAssertEqual(models, ["video_sr", "image", "video"])
    XCTAssertEqual(state.draft.text, "Восстановленный запрос")
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    await state.close()
    try await harness.close()
  }

  func testOfflineSourceUploadKeepsThePhotoAndWaitsForAReconnectBeforeRetrying() async throws {
    guard NetworkProfile.origin.host == "127.0.0.1", NetworkProfile.origin.port == 1 else {
      throw XCTSkip("Нужен отдельный запуск с недоступным местным адресом")
    }
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { try NetworkSchema.install($0) }
    let sync = NetworkSync(profile: testProfile(), store: harness.store, local: harness.repo)
    let media = MediaStore(store: harness.store)
    let admission = MediaAdmission()
    let state = ConversationState(repository: harness.repo)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let photo = try await media.stageStudioPhoto(
      sourceURL: fixtures.appendingPathComponent("media/photo-000.jpg"))
    let selected = try media.fileURL(photo.relativePath)
    let original = try Data(contentsOf: selected)
    try await state.open(chatID: 2)
    var draft = Draft(text: "Движение после восстановления связи")
    draft.attachmentDrafts = [photo]
    draft.generationOptions = KandinskyOptions(model: "video")
    state.editDraft(draft)
    try await state.flush()

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    let first = expectation(description: "Первая передача завершилась без связи")
    let second = expectation(description: "После восстановления разрешена ещё одна попытка")
    var completed = 0
    var starts = 0
    var errors: [String] = []
    let coordinator = ChatAttachmentCoordinator(
      view: root.view, state: state, media: media, admission: admission, presenter: { root },
      options: { KandinskyOptions(model: "video") }, selectOptions: { _ in },
      showError: { errors.append($0) }, previewVideo: { _, _, _ in XCTFail("Ожидается фото") },
      showProgress: { progress in
        if progress != nil {
          if starts == completed { starts += 1 }
          return
        }
        completed += 1
        if completed == 1 { first.fulfill() }
        if completed == 2 { second.fulfill() }
      })
    coordinator.network = sync
    defer {
      coordinator.close(discardDraft: false)
      sync.close()
      media.close()
      admission.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }

    coordinator.resumePendingUpload()
    await fulfillment(of: [first], timeout: 8)
    XCTAssertFalse(coordinator.isImporting)
    coordinator.resumePendingUpload()
    XCTAssertFalse(coordinator.isImporting)
    coordinator.resumePendingUpload(reconnected: true)
    await fulfillment(of: [second], timeout: 8)

    XCTAssertEqual(starts, 2)
    XCTAssertEqual(completed, 2)
    XCTAssertTrue(errors.isEmpty)
    XCTAssertEqual(try Data(contentsOf: selected), original)
    let saved = try await harness.repo.draft(chatID: 2)
    XCTAssertEqual(saved.text, draft.text)
    XCTAssertEqual(saved.attachmentDrafts.map(\.id), [photo.id])
    let uploaded = try await sync.hasStudioUpload(photo.id)
    XCTAssertFalse(uploaded)
    await state.close()
    try await harness.close()
  }

  func testSelectingAnImageModelRemovesTheIncompatibleVideoFromTheSavedDraft() async throws {
    let harness = try await RepositoryHarness.open()
    try await harness.store.perform { try NetworkSchema.install($0) }
    let profile = testProfile()
    let catalogue = Data(
      """
      {"models":[{
        "id":"image", "name":"Изображение", "description":"Из текста",
        "capabilities":{
          "quality":[], "resolutions":[], "aspects":["1:1"], "duration_seconds":[],
          "max_count":4, "negative_prompt":false
        }
      }]}
      """.utf8)
    let api = ScriptedHTTP.makeAPI([.response(200, catalogue)], profile: profile)
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
    let media = MediaStore(store: harness.store)
    let admission = MediaAdmission()
    let state = ConversationState(repository: harness.repo)
    let chrome = ConversationChrome(
      chatID: 2, state: state, media: media, admission: admission, onBack: {})
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    chrome.frame = parent.view.bounds
    parent.view.addSubview(chrome)
    chrome.configureNetwork(sync)
    defer {
      chrome.persistAnchorAndClose()
      parent.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
      sync.close()
      admission.close()
      media.close()
    }

    try await state.open(chatID: 2)
    try await chrome.openHistory(repository: harness.repo, anchor: nil)
    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let video = try await media.stageSelection(
      sourceURL: fixtures.appendingPathComponent("real-media/backend-990da02cd31e46cfb8fd630c293f3489.mp4"),
      mime: "video/mp4")
    let file = try media.fileURL(video.relativePath)
    var draft = Draft(text: "Описание нужно сохранить")
    draft.attachmentDrafts = [video]
    draft.generationOptions = KandinskyOptions(model: "video_sr")
    state.editDraft(draft)
    try await state.flush()

    try XCTUnwrap(control("composer.model", in: chrome)).sendActions(for: .touchUpInside)
    let modelsAppear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      guard let sheet = parent.presentedViewController as? StudioGenerationSheet else { return false }
      return !sheet.isBeingPresented
    }, object: nil)
    await fulfillment(of: [modelsAppear], timeout: 5)
    let sheet = try XCTUnwrap(parent.presentedViewController as? StudioGenerationSheet)
    func imageChoice(in view: UIView) -> UIButton? {
      if let button = view as? UIButton, button.accessibilityLabel == "Изображение" {
        return button
      }
      return view.subviews.lazy.compactMap(imageChoice(in:)).first
    }
    try XCTUnwrap(imageChoice(in: sheet.view)).sendActions(for: .touchUpInside)

    let withdrawn = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      state.draft.attachmentDrafts.isEmpty && state.draft.generationOptions?.model == "image"
        && !FileManager.default.fileExists(atPath: file.path)
    }, object: nil)
    await fulfillment(of: [withdrawn], timeout: 6)
    var saved = try await harness.repo.draft(chatID: 2)
    for _ in 0..<50 where saved.generationOptions?.model != "image" || !saved.attachmentDrafts.isEmpty {
      try await Task.sleep(for: .milliseconds(25))
      saved = try await harness.repo.draft(chatID: 2)
    }
    XCTAssertEqual(saved.text, "Описание нужно сохранить")
    XCTAssertEqual(saved.generationOptions?.model, "image")
    XCTAssertTrue(saved.attachmentDrafts.isEmpty)
    XCTAssertEqual(ScriptedHTTP.requests().compactMap { $0.url?.path }, ["/v1/kandinsky/models"])
    await state.close()
    try await harness.close()
  }

  func testOutgoingPayloadWaitsForAcceptedReplyAndUsesSavedAttachments() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }

    let photo = AttachmentDraft(
      id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", relativePath: "photo.jpg", mime: "image/jpeg",
      byteSize: 42, rawWidth: 18, rawHeight: 26, orientation: 6, thumbnailKey: "thumb",
      tinyPreview: "small")
    let voice = AttachmentDraft(
      id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", relativePath: "voice.m4a", mime: "audio/mp4",
      byteSize: 60, durationMs: 750, waveform: [0, 128, 255])
    let photoBlob = String(repeating: "3", count: 32)
    let previewBlob = String(repeating: "4", count: 32)
    let voiceBlob = String(repeating: "5", count: 32)
    try await harness.store.perform { db in
      try NetworkSchema.install(db)
      try db.execute(
        "INSERT INTO net_messages(localID,serverID,clientID,senderID) VALUES (81,901,'accepted',7),(82,NULL,'pending',7)")
      try db.execute(
        "INSERT INTO net_uploads(attachmentID,blobID,previewBlobID) VALUES (?,?,?),(?,?,NULL)",
        [.text(photo.id), .text(photoBlob), .text(previewBlob), .text(voice.id), .text(voiceBlob)])
    }

    let unaccepted = SendCommand(operationID: "FIRST", chatID: 2, text: "Ждём", replyToID: 82)
    let reply = SendCommand(
      operationID: "SECOND", chatID: 2, kind: .photo, text: "Ответ", caption: "Подпись",
      replyToID: 81, attachments: [photo, voice],
      generationOptions: KandinskyOptions(model: "video", duration_seconds: 1, resolution: "compact"))
    let plain = SendCommand(operationID: "THIRD", chatID: 2, text: "Обычный текст")
    let messages = try await sync.prepare([unaccepted, reply, plain])

    XCTAssertEqual(messages.compactMap { $0["clientId"] as? String }, ["second", "third"])
    let first = try XCTUnwrap(messages.first)
    XCTAssertEqual(first["chatId"] as? Int64, 2)
    XCTAssertEqual(first["replyToId"] as? Int64, 901)
    XCTAssertEqual(first["text"] as? String, "Ответ")
    XCTAssertEqual(first["caption"] as? String, "Подпись")
    let options = try XCTUnwrap(first["generationOptions"] as? [String: Any])
    XCTAssertEqual(options["model"] as? String, "video")
    XCTAssertEqual(options["duration_seconds"] as? Int, 1)
    XCTAssertEqual(options["resolution"] as? String, "compact")
    let assets = try XCTUnwrap(first["attachments"] as? [[String: Any]])
    XCTAssertEqual(assets.count, 2)
    let firstAsset = try XCTUnwrap(assets.first)
    let secondAsset = try XCTUnwrap(assets.dropFirst().first)
    XCTAssertEqual(assets.map { $0["blobId"] as? String }, [photoBlob, voiceBlob])
    XCTAssertEqual(firstAsset["previewBlobId"] as? String, previewBlob)
    XCTAssertEqual(firstAsset["rawWidth"] as? Int, 18)
    XCTAssertEqual(firstAsset["orientation"] as? Int, 6)
    XCTAssertEqual(firstAsset["tinyPreview"] as? String, "small")
    XCTAssertTrue(secondAsset["previewBlobId"] is NSNull)
    XCTAssertEqual(secondAsset["durationMs"] as? Int64, 750)
    XCTAssertEqual(secondAsset["waveform"] as? [UInt8], [0, 128, 255])
    let last = try XCTUnwrap(messages.last)
    XCTAssertTrue(last["replyToId"] is NSNull)
    XCTAssertNil(last["generationOptions"])
    XCTAssertEqual((last["attachments"] as? [[String: Any]])?.count, 0)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_uploads"), 2)
    try await harness.close()
  }

  func testOutgoingGifUploadIsStoredForTheNextPreparation() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let blob = String(repeating: "8", count: 32)
    let response = try JSONEncoder().encode(["blobId": blob])
    let api = ScriptedHTTP.makeAPI([.response(201, response)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await harness.store.perform { db in try NetworkSchema.install(db) }

    let fixtures = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    let source = fixtures.appendingPathComponent("media/gif-06.gif")
    let mediaFolder = harness.root.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: mediaFolder.appendingPathComponent("source.gif"))
    let size = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let attachment = AttachmentDraft(
      id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", relativePath: "source.gif", mime: "image/gif",
      byteSize: Int64(size))
    let command = SendCommand(
      operationID: "SEND-GIF", chatID: 2, kind: .gif, attachments: [attachment])

    for _ in 0..<2 {
      let messages = try await sync.prepare([command])
      let message = try XCTUnwrap(messages.first)
      let assets = try XCTUnwrap(message["attachments"] as? [[String: Any]])
      XCTAssertEqual(assets.count, 1)
      XCTAssertEqual(assets.first?["blobId"] as? String, blob)
      XCTAssertTrue(assets.first?["previewBlobId"] is NSNull)
    }

    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["PUT"])
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.path, "/v1/uploads/cccccccc-cccc-cccc-cccc-cccccccccccc")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/gif")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-kandinsky-chat"), "2")
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_uploads WHERE blobID='\(blob)'"), 1)
    try await harness.close()
  }

  func testChatCreationReusesDraftIDAfterLosingReplies() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let chat = Data(
      #"{"chat":{"id":35,"title":"Новый чат","lastSeq":0,"unreadCount":0,"pinned":false,"archived":false}}"#.utf8)
    let api = ScriptedHTTP.makeAPI([
      .failure(.networkConnectionLost), .response(503, Data()), .response(201, chat),
    ], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await harness.store.perform { db in try NetworkSchema.install(db) }
    let draft = try XCTUnwrap(UUID(uuidString: "71D7CBAE-DA2A-4C14-9E98-4E2E442D9B08"))

    let received = try await sync.createStudioThread(id: draft)

    XCTAssertEqual(received, 35)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats WHERE chatID=35"), 1)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST"])
    XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/v1/demo/chats", count: 3))
    XCTAssertEqual(try requests.map(requestJSON),
                   Array(repeating: ["id": "71d7cbae-da2a-4c14-9e98-4e2e442d9b08"], count: 3))
    try await harness.close()
  }

  func testRejectedOrMalformedChatCreationLeavesLocalDirectoryIntact() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([.response(409, Data()), .response(201, Data("{}".utf8))], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await harness.store.perform { db in try NetworkSchema.install(db) }

    do {
      _ = try await sync.createStudioThread(id: UUID())
      XCTFail("Ожидался отказ сервера")
    } catch let error as NetworkFailure {
      XCTAssertEqual(error.status, 409)
    }
    XCTAssertEqual(ScriptedHTTP.requests().count, 1)

    do {
      _ = try await sync.createStudioThread(id: UUID())
      XCTFail("Ожидалась ошибка ответа без карточки чата")
    } catch RepoError.corrupt {}
    XCTAssertEqual(ScriptedHTTP.requests().count, 2)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats"), 0)
    try await harness.close()
  }

  func testArchiveSearchKeepsLiteralPlusAndPageLimits() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let page = Data(
      #"{"threads":[{"id":42,"title":"C++ & фото","lastSeq":9,"unreadCount":0,"pinned":false,"archived":true}]}"#.utf8)
    let api = ScriptedHTTP.makeAPI([.response(200, page)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }

    let result = try await sync.studioThreads(view: "archive", query: "C++ & фото", offset: 16, limit: 8)

    let thread = try XCTUnwrap(result.first)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(thread.id, 42)
    XCTAssertEqual(thread.title, "C++ & фото")
    XCTAssertTrue(thread.archived)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.count, 1)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "GET")
    let url = try XCTUnwrap(request.url)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/v1/kandinsky/threads")
    XCTAssertEqual(components.queryItems, [
      .init(name: "view", value: "archive"), .init(name: "q", value: "C++ & фото"),
      .init(name: "offset", value: "16"), .init(name: "limit", value: "8"),
    ])
    XCTAssertTrue(try XCTUnwrap(components.percentEncodedQuery).contains("C%2B%2B"))
    try await harness.close()
  }

  func testOpeningHistoryRequestsOnceAndDeliversTheSavedMessages() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let body = try historyPage([(52, 2)], hasOlder: true)
    let api = ScriptedHTTP.makeAPI([.response(200, body)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await seedHistoryChat(sync)
    sync.history.visibleHistoryRefreshes = Dictionary(
      uniqueKeysWithValues: (100...131).map { (Int64($0), TimeInterval($0 - 200)) })

    let delivered = expectation(description: "История записана и передана экрану")
    delivered.assertForOverFulfill = true
    sync.onDeltas = { changes in
      XCTAssertEqual(changes.map(\.chat.id), [2])
      XCTAssertEqual(changes.flatMap(\.updated).map(\.text), ["Сообщение 52"])
      delivered.fulfill()
    }
    sync.visibleChat(2)
    sync.visibleChat(2)
    sync.refreshVisibleHistory(2)
    await fulfillment(of: [delivered], timeout: 3)

    let stored = try await local.history(PageRequest(chatID: 2))
    XCTAssertEqual(stored.rows.map(\.text), ["Сообщение 52"])
    XCTAssertEqual(try harness.rawScalar("SELECT hasOlder FROM net_chats WHERE chatID=2"), 1)
    XCTAssertEqual(sync.history.currentChat, 2)
    XCTAssertNotNil(sync.history.visibleHistoryRefreshes[2])
    XCTAssertEqual(sync.history.visibleHistoryRefreshes.count, 32)
    XCTAssertNil(sync.history.visibleHistoryRefreshes[100])
    XCTAssertNotNil(sync.history.visibleHistoryRefreshes[101])
    XCTAssertTrue(sync.history.loadingHistory.isEmpty)

    sync.visibleChat(nil)
    XCTAssertNil(sync.history.currentChat)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.path, "/v1/chats/2/history")
    XCTAssertEqual(requests.first?.url?.query, "limit=128")
    try await harness.close()
  }

  func testHistoryRejectsAnotherChatsMessageAndKeepsItsPreviousPage() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let previous = try historyPage([(51, 2)], hasOlder: true)
    let mixed = try historyPage([(52, 2), (90, 7)], hasOlder: false)
    let api = ScriptedHTTP.makeAPI([.response(200, mixed)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await seedHistoryChat(sync)
    try await harness.store.perform { [cache = sync.cache] db in
      _ = try cache.history(db, chat: 2, data: previous)
    }

    let unavailable = expectation(description: "Экран сообщает об ошибке истории открытого чата")
    sync.onStatus = { status in
      XCTAssertEqual(status, "История временно недоступна")
      unavailable.fulfill()
    }
    sync.onDeltas = { _ in XCTFail("Ошибка страницы не должна менять экран") }
    sync.visibleChat(2)
    await fulfillment(of: [unavailable], timeout: 3)

    let stored = try await local.history(PageRequest(chatID: 2))
    XCTAssertEqual(stored.rows.map(\.text), ["Сообщение 51"])
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_messages WHERE serverID IN (52,90)"), 0)
    XCTAssertEqual(try harness.rawScalar("SELECT hasOlder FROM net_chats WHERE chatID=2"), 1)
    XCTAssertNil(sync.history.visibleHistoryRefreshes[2])
    XCTAssertTrue(sync.history.loadingHistory.isEmpty)
    try await harness.close()
  }

  func testIncomingEventsLoadAnUnknownChatAndIgnoreAStaleConnection() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let catalog = Data(
      #"{"chats":[{"id":7,"title":"Новый чат","lastSeq":0,"unreadCount":0,"pinned":false}]}"#.utf8)
    let api = ScriptedHTTP.makeAPI([.response(200, catalog)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await harness.store.perform { db in try NetworkSchema.install(db) }
    let received = Data(
      """
      {"type":"events","cursor":1,"events":[{"seq":1,"chatId":7,"kind":"message","message":{
        "id":201,"chatId":7,"seq":21,"senderId":1,"clientId":"received-201","kind":"text",
        "text":"Новое сообщение","caption":"","savedAtMs":1000,"revision":1,"attachments":[]}}]}
      """.utf8)
    let epoch = sync.connectionEpoch
    var directoryUpdates = 0
    sync.onStudioRecentChanged = { directoryUpdates += 1 }

    try await sync.receiveFrame(received, connectionID: epoch - 1)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_messages"), 0)

    try await sync.receiveFrame(received, connectionID: epoch)
    try await sync.receiveFrame(received, connectionID: epoch)
    let stored = try await local.history(PageRequest(chatID: 7))
    XCTAssertEqual(stored.rows.map(\.text), ["Новое сообщение"])
    XCTAssertEqual(directoryUpdates, 1)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_messages WHERE serverID=201"), 1)
    XCTAssertEqual(try harness.rawScalar("SELECT CAST(value AS INTEGER) FROM net_state WHERE key='cursor'"), 1)
    XCTAssertEqual(ScriptedHTTP.requests().compactMap { $0.url?.path }, ["/v1/chats"])

    sync.cursorAcknowledgement.inFlight = 1
    for (cursor, storedCount) in [(2, 0), (1, 1)] {
      let response = Data(#"{"type":"applied","cursor":\#(cursor)}"#.utf8)
      try await sync.receiveFrame(response, connectionID: epoch)
      XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_state WHERE key='ackedCursor'"),
                     storedCount)
    }
    XCTAssertNil(sync.cursorAcknowledgement.inFlight)
    XCTAssertEqual(
      try harness.rawScalar("SELECT CAST(value AS INTEGER) FROM net_state WHERE key='ackedCursor'"), 1)
    try await harness.close()
  }

  func testRemovedMediaFromServerIsEvictedInBatchesWithoutTouchingOtherFiles() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let sync = NetworkSync(profile: profile, store: h.store, local: h.repo, api: api)
    sync.studioMedia = NetworkMedia(store: h.store, api: api)
    defer { sync.close() }
    try await h.store.perform { try NetworkSchema.install($0) }

    let bytes = Data("Данные только для проверки".utf8)
    func cached(_ relative: String) throws -> URL {
      let path = try MediaStore.fileURL(root: h.root, relative: relative)
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: path)
      return path
    }
    let retained = try cached("remote/" + String(repeating: "f", count: 32) + ".jpg")
    var removedFiles: [URL] = []
    var media: [[String: String]] = []
    for index in 1...17 {
      let blob = String(format: "%032x", index)
      let preview = String(format: "%032x", index + 100)
      media.append(["blobId": blob, "previewBlobId": preview])
      removedFiles.append(try cached("remote/" + blob + ".jpg"))
      removedFiles.append(try cached("previews/" + preview + ".jpg"))
    }
    let events: [[String: Any]] = [
      ["seq": 1, "chatId": 2, "kind": "deleted", "messageId": 81, "removedMedia": Array(media.prefix(9))],
      ["seq": 2, "chatId": 2, "kind": "deleted", "messageId": 82, "removedMedia": Array(media.suffix(8))],
    ]
    let frame = try JSONSerialization.data(withJSONObject: [
      "type": "events", "cursor": 2, "events": events,
    ])
    let removed = expectation(description: "Обе порции очищены с уведомлением экрана")
    removed.expectedFulfillmentCount = 2
    removed.assertForOverFulfill = true
    sync.onStudioMediaEvicted = { removed.fulfill() }

    try await sync.receiveFrame(frame, connectionID: sync.connectionEpoch)
    await fulfillment(of: [removed], timeout: 8)
    XCTAssertTrue(removedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(try Data(contentsOf: retained), bytes)
    let pendingRemoval = "SELECT count(*) FROM net_state WHERE key LIKE 'studioRemoved:%'"
    for _ in 0..<50 {
      if try h.rawScalar(pendingRemoval) == 0 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(try h.rawScalar(pendingRemoval), 0)
    XCTAssertEqual(try h.rawScalar("SELECT count(*) FROM net_tombstones"), 2)

    try await sync.receiveFrame(frame, connectionID: sync.connectionEpoch)
    XCTAssertEqual(try h.rawScalar(pendingRemoval), 0)
    XCTAssertEqual(try Data(contentsOf: retained), bytes)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    try await h.close()
  }

  func testDelayedDeletionConfirmationKeepsTheNextQueuedRequestInFlight() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    let outboxWake = expectation(description: "Удаление будит очередь отправки один раз")
    outboxWake.assertForOverFulfill = true
    let repository = NetworkChatRepository(local: local) { outboxWake.fulfill() }
    try await seedHistoryChat(sync)
    let commandID = UUID().uuidString.lowercased()
    let sent = try await local.send(.init(operationID: commandID, chatID: 2, text: "Уже отправлено"))
    let message = try XCTUnwrap(sent.inserted.first)
    try await sync.receiveFrame(
      Data(
        """
        {"type":"accepted","requestId":"send","messages":[
          {"id":101,"seq":42,"savedAtMs":1000,"clientId":"\(commandID)"}]}
        """.utf8), connectionID: sync.connectionEpoch)
    let found = try await repository.search(chatID: 2, text: "Уже отправлено", before: nil)
    XCTAssertEqual(found, [message.id])
    let removed = try await repository.delete(messageID: message.id)
    XCTAssertEqual(removed.removedIDs, [message.id])
    await fulfillment(of: [outboxWake], timeout: 2)
    let afterRemoval = try await repository.search(chatID: 2, text: "Уже отправлено", before: nil)
    XCTAssertTrue(afterRemoval.isEmpty)
    let deletionID = try await harness.store.perform { db in
      try NetworkJournal.readyOperations(db).first?["id"]?.string
    }
    let deleted = try XCTUnwrap(deletionID)
    let otherID = UUID().uuidString.lowercased()
    let second = try await local.send(.init(operationID: otherID, chatID: 2, text: "Ждёт ответа"))
    let following = try XCTUnwrap(second.inserted.first)
    sync.outbox.pendingRequestID = "new"
    sync.outbox.pendingOperationIDs = [otherID]

    func confirmDeletion() async throws {
      try await sync.receiveFrame(
        Data(#"{"type":"deleted","requestId":"\#(deleted)"}"#.utf8),
        connectionID: sync.connectionEpoch)
    }
    try await confirmDeletion()
    XCTAssertEqual(sync.outbox.pendingRequestID, "new")
    XCTAssertEqual(sync.outbox.pendingOperationIDs, [otherID])
    let history = try await repository.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(history.map(\.id), [following.id])
    XCTAssertEqual(history.first?.delivery, .pending)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='send'"), 1)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE action='delete'"), 0)
    try await confirmDeletion()
    XCTAssertEqual(sync.outbox.pendingRequestID, "new")
    sync.outbox.pendingRequestID = deleted
    try await confirmDeletion()
    XCTAssertNil(sync.outbox.pendingRequestID)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    try await harness.close()
  }

  func testAcknowledgementAndRejectionUpdateOnlyTheirOwnOutgoingRows() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let local = SQLiteChatRepository(store: harness.store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await seedHistoryChat(sync)

    let firstID = UUID().uuidString.lowercased()
    let secondID = UUID().uuidString.lowercased()
    let first = try await local.send(.init(operationID: firstID, chatID: 2, text: "Принято"))
    let second = try await local.send(.init(operationID: secondID, chatID: 2, text: "Отказ"))
    let acceptedID = try XCTUnwrap(first.inserted.first?.id)
    let rejectedID = try XCTUnwrap(second.inserted.first?.id)
    sync.outbox.pendingRequestID = "first"
    sync.outbox.pendingOperationIDs = [firstID]
    let epoch = sync.connectionEpoch
    let accepted = Data(
      """
      {"type":"accepted","requestId":"first","messages":[
        {"id":101,"seq":42,"savedAtMs":1000,"clientId":"\(firstID)"}]}
      """.utf8)
    try await sync.receiveFrame(accepted, connectionID: epoch)

    XCTAssertNil(sync.outbox.pendingRequestID)
    XCTAssertTrue(sync.outbox.pendingOperationIDs.isEmpty)
    let sent = try await local.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(sent.first { $0.id == acceptedID }?.delivery, .accepted)
    XCTAssertEqual(sent.first { $0.id == rejectedID }?.delivery, .pending)
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox"), 1)

    sync.outbox.pendingRequestID = "second"
    sync.outbox.pendingOperationIDs = [secondID]
    do {
      try await sync.receiveFrame(
        Data(#"{"type":"error","requestId":"second","code":"busy","retryable":true}"#.utf8),
        connectionID: epoch)
      XCTFail("Временный отказ должен позволить повторить команду")
    } catch RepoError.io {}
    XCTAssertEqual(sync.outbox.pendingRequestID, "second")
    do {
      try await sync.receiveFrame(
        Data(#"{"type":"error","requestId":"first","code":"unsupported"}"#.utf8),
        connectionID: epoch)
      XCTFail("Запоздалый отказ чужой операции не должен менять текущую отправку")
    } catch RepoError.io {}
    XCTAssertEqual(sync.outbox.pendingRequestID, "second")
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE errorCode IS NULL"), 1)

    var status: String?
    sync.onStatus = { status = $0 }
    try await sync.receiveFrame(
      Data(#"{"type":"error","requestId":"second","code":"unsupported"}"#.utf8),
      connectionID: epoch)
    let settled = try await local.history(PageRequest(chatID: 2)).rows
    XCTAssertEqual(settled.first { $0.id == acceptedID }?.delivery, .accepted)
    XCTAssertEqual(settled.first { $0.id == rejectedID }?.delivery, .failed)
    XCTAssertNil(sync.outbox.pendingRequestID)
    XCTAssertEqual(status, "Не отправлено: unsupported")
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_outbox WHERE errorCode='unsupported'"), 1)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    try await harness.close()
  }

  func testGenerationModelsUseTheServersOptionsAndRejectAnIncompleteModel() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let catalog = Data(
      """
      {
        "models": [
          {
            "id":"video", "name":"Видео", "description":"Создание ролика",
            "capabilities":{
              "quality":[{"id":"fast","name":"Быстро"}],
              "resolutions":[{"id":"medium","name":"Среднее","sizes":{"9:16":[576,1024]}}],
              "aspects":["9:16","16:9"], "duration_seconds":[1,5], "max_count":4,
              "negative_prompt":true, "guidance":{"min":1,"max":8,"default":4.5}
            },
            "reference_capabilities":{
              "quality":[], "resolutions":[], "aspects":["9:16"], "duration_seconds":[1],
              "max_count":1, "negative_prompt":false
            }
          },
          {"id":"video_sr","name":"Улучшение видео","description":"Увеличение размера"}
        ]
      }
      """.utf8)
    let invalid = Data(#"{"models":[{"id":"video","name":"Видео","description":"Без настроек"}]}"#.utf8)
    let api = ScriptedHTTP.makeAPI([.response(200, catalog), .response(200, invalid)], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }

    let models = try await sync.studioModels()
    XCTAssertEqual(models.map(\.id), ["video", "video_sr"])
    let video = try XCTUnwrap(models.first?.capabilities)
    XCTAssertEqual(video.quality.map(\.id), ["fast"])
    XCTAssertEqual(video.resolutions.first?.label(aspect: "9:16"), "576 × 1024")
    XCTAssertEqual(video.resolutions.first?.label(aspect: "16:9"), "Среднее")
    XCTAssertEqual(video.duration_seconds, [1, 5])
    XCTAssertEqual(video.max_count, 4)
    XCTAssertEqual(video.guidance?.default, 4.5)
    XCTAssertTrue(video.negative_prompt)
    XCTAssertEqual(models.first?.reference_capabilities?.max_count, 1)
    XCTAssertNil(models.first?.reference_capabilities?.guidance)
    XCTAssertNil(models.last?.capabilities)

    do {
      _ = try await sync.studioModels()
      XCTFail("Обычная модель требует настроек")
    } catch DecodingError.keyNotFound(let key, _) {
      XCTAssertEqual(key.stringValue, "capabilities")
    }
    XCTAssertEqual(ScriptedHTTP.requests().compactMap { $0.url?.path },
                   ["/v1/kandinsky/models", "/v1/kandinsky/models"])
    try await harness.close()
  }

  func testGenerationSettingsCanRecoverFromAnUnavailableModelCatalog() async throws {
    let h = try await RepositoryHarness.open()
    let profile = testProfile()
    let catalog = Data("""
      {"models":[
        {"id":"video","name":"Видео","description":"Создание видео","capabilities":{
          "quality":[],"resolutions":[],"aspects":["9:16"],"duration_seconds":[1],
          "max_count":4,"negative_prompt":false}},
        {"id":"video_sr","name":"Улучшение","description":"Увеличение размера"}
      ]}
      """.utf8)
    let api = ScriptedHTTP.makeAPI([.response(503, Data()), .response(200, catalog)], profile: profile)
    let sync = NetworkSync(profile: profile, store: h.store, local: h.repo, api: api)
    try await h.store.perform { try NetworkSchema.install($0) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    let state = ConversationState(repository: h.repo)
    let chrome = ConversationChrome(chatID: 2, state: state, onBack: {})
    chrome.frame = parent.view.bounds
    parent.view.addSubview(chrome)
    defer {
      parent.dismiss(animated: false)
      chrome.persistAnchorAndClose()
      sync.close()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    chrome.configureNetwork(sync)
    try await state.open(chatID: 2)
    try await chrome.openHistory(repository: h.repo, anchor: nil)
    chrome.restoreGenerationOptions(.init(model: "video"))

    let settings = try XCTUnwrap(control("composer.settings", in: chrome))
    settings.sendActions(for: .touchUpInside)
    let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (parent.presentedViewController as? UIAlertController)?.title == "Не удалось загрузить модели"
    }, object: nil)
    await fulfillment(of: [failed], timeout: 6)
    await withCheckedContinuation { continuation in
      parent.dismiss(animated: false) { continuation.resume() }
    }

    settings.sendActions(for: .touchUpInside)
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      parent.presentedViewController is StudioGenerationSheet
    }, object: nil)
    await fulfillment(of: [ready], timeout: 6)
    let sheet = try XCTUnwrap(parent.presentedViewController as? StudioGenerationSheet)
    let count = try XCTUnwrap(control("studio.option.Количество.4", in: sheet.view))
    count.sendActions(for: .touchUpInside)
    XCTAssertEqual(chrome.generationOptions.count, 4)
    await withCheckedContinuation { continuation in
      parent.dismiss(animated: false) { continuation.resume() }
    }

    for unavailable in ["image", "video_sr"] {
      chrome.restoreGenerationOptions(.init(model: unavailable))
      settings.sendActions(for: .touchUpInside)
      XCTAssertNil(parent.presentedViewController)
    }
    XCTAssertEqual(ScriptedHTTP.requests().compactMap { $0.url?.path },
                   ["/v1/kandinsky/models", "/v1/kandinsky/models"])
    await state.close()
    try await h.close()
  }

  func testChatChangesAndRemovalAppearOnlyAfterTheServerConfirmsThem() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let archived = Data(
      #"{"id":2,"title":"Подтверждённый архив","lastSeq":52,"unreadCount":0,"pinned":false,"archived":true}"#.utf8)
    let restored = Data(
      #"{"id":2,"title":"Подтверждённый архив","lastSeq":52,"unreadCount":0,"pinned":false,"archived":false}"#.utf8)
    let api = ScriptedHTTP.makeAPI([
      .response(409, Data()), .response(200, archived), .response(200, restored),
      .response(409, Data()), .response(204, Data()), .response(204, Data()),
    ], profile: profile)
    let local = SQLiteChatRepository(store: harness.store)
    let repository = NetworkChatRepository(local: local, wake: {})
    let sync = NetworkSync(profile: profile, store: harness.store, local: local, api: api)
    defer { sync.close() }
    try await seedHistoryChat(sync)
    let page = try historyPage([(52, 2)], hasOlder: false)
    try await harness.store.perform { [cache = sync.cache] db in
      _ = try cache.history(db, chat: 2, data: page)
    }
    let original = try await repository.history(PageRequest(chatID: 2))
    let row = try XCTUnwrap(original.rows.first)
    let archive = StudioThreadChange(title: "Архив", archived: true)

    do {
      try await sync.changeStudioThread(2, change: archive)
      XCTFail("Отказ сервера должен сохранить карточку без изменений")
    } catch let error as NetworkFailure {
      XCTAssertEqual(error.status, 409)
    }
    let unchanged = try await repository.chats(matching: "")
    XCTAssertFalse(try XCTUnwrap(unchanged.first { $0.id == 2 }).archived)
    try await sync.changeStudioThread(2, change: archive)
    let moved = try await repository.chats(matching: "")
    XCTAssertTrue(try XCTUnwrap(moved.first { $0.id == 2 }).archived)
    XCTAssertEqual(moved.first { $0.id == 2 }?.title, "Подтверждённый архив")
    try await sync.changeStudioThread(2, change: StudioThreadChange(archived: false))
    let returned = try await repository.chats(matching: "")
    XCTAssertFalse(try XCTUnwrap(returned.first { $0.id == 2 }).archived)

    do {
      try await sync.deleteStudioThread(2)
      XCTFail("Отказ сервера должен сохранить историю")
    } catch let error as NetworkFailure {
      XCTAssertEqual(error.status, 409)
    }
    let stillThere = try await repository.history(PageRequest(chatID: 2))
    XCTAssertEqual(stillThere.rows.map(\.id), [row.id])
    try await sync.deleteStudioThread(2)
    let directory = try await repository.chats(matching: "")
    XCTAssertFalse(directory.contains { $0.id == 2 })
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM messages WHERE chatId=2"), 0)
    try await sync.deleteStudioThread(2)
    let afterRepeatedConfirmation = try await repository.chats(matching: "")
    XCTAssertEqual(afterRepeatedConfirmation.map(\.id), directory.map(\.id))
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM messages WHERE chatId=2"), 0)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.compactMap(\.httpMethod),
                   ["PATCH", "PATCH", "PATCH", "DELETE", "DELETE", "DELETE"])
    XCTAssertEqual(requests.compactMap { $0.url?.path }, Array(repeating: "/v1/kandinsky/threads/2", count: 6))
    try await harness.close()
  }

  func testUploadProgressRejectsDuplicatesAndIgnoresAnOlderConnection() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = testProfile()
    let api = ScriptedHTTP.makeAPI([], profile: profile)
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
    defer { sync.close() }
    let id = "71d7cbae-da2a-4c14-9e98-4e2e442d9b08"
    let device = "2dc2f71b-1ba1-4c16-b85b-3305bcdbee53"
    let transfer: [String: Any] = ["id": id, "deviceId": device, "received": 75, "total": 300, "mime": "video/mp4"]
    func frame(_ rows: [[String: Any]]) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["type": "kandinsky.uploads", "uploads": rows])
    }
    var visibleUpdates = 0
    sync.onStudioTransfersChanged = { visibleUpdates += 1 }
    let epoch = sync.connectionEpoch

    try await sync.receiveFrame(frame([transfer]), connectionID: epoch)
    XCTAssertEqual(sync.studioTransfers.map(\.id), [id])
    XCTAssertEqual(sync.studioTransfers.first?.progress, 0.25)
    XCTAssertEqual(visibleUpdates, 1)
    try await sync.receiveFrame(frame([]), connectionID: epoch - 1)
    XCTAssertEqual(sync.studioTransfers.map(\.id), [id])
    var invalid = transfer
    invalid["received"] = 301
    for rows in [[transfer, transfer], [invalid], Array(repeating: transfer, count: 9)] {
      do {
        try await sync.receiveFrame(frame(rows), connectionID: epoch)
        XCTFail("Неисправная порция не должна менять текущие загрузки")
      } catch RepoError.corrupt {}
      XCTAssertEqual(sync.studioTransfers.map(\.id), [id])
    }

    try await sync.receiveFrame(frame([]), connectionID: epoch)
    XCTAssertTrue(sync.studioTransfers.isEmpty)
    XCTAssertEqual(visibleUpdates, 2)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    try await harness.close()
  }

  private func seedHistoryChat(_ sync: NetworkSync) async throws {
    let chat = Data(
      #"{"chats":[{"id":2,"title":"История","lastSeq":0,"unreadCount":0,"pinned":false}]}"#.utf8)
    try await sync.store.perform { [cache = sync.cache] db in
      try NetworkSchema.install(db)
      _ = try cache.mergeChats(db, data: chat)
    }
  }

  private func historyPage(_ rows: [(id: Int64, chat: Int64)], hasOlder: Bool) throws -> Data {
    let messages: [[String: Any]] = rows.map { row in
      [
        "id": row.id, "chatId": row.chat, "seq": row.id, "senderId": 1,
        "clientId": "history-\(row.id)", "kind": "text", "text": "Сообщение \(row.id)",
        "caption": "", "savedAtMs": 1_794_483_289_395 + row.id, "revision": 1,
        "attachments": [],
      ]
    }
    return try JSONSerialization.data(withJSONObject: ["messages": messages, "hasOlder": hasOlder])
  }

  // Ищет элемент управления по признаку доступности среди вложенных представлений. Тест нажимает
  // нужную кнопку даже после перестройки экранных частей.
  private func control(_ id: String, in view: UIView) -> UIControl? {
    if let control = view as? UIControl, control.accessibilityIdentifier == id { return control }
    return view.subviews.lazy.compactMap { self.control(id, in: $0) }.first
  }

  // Устанавливает нужные таблицы, записывает ответ неудачной генерации и читает одну строку через
  // хранилище истории. Повтор проверяется на реально записанном местном состоянии.
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

  // Готовит ответ для одной и той же строки до и после запуска. Разные версии и ход работы дают
  // проверить обновление вместо появления второй строки.
  private func generationResponse(
    job: String, running: Bool, slots: [StudioGeneration.Slot]? = nil
  ) throws -> Data {
    var metadata: [String: Any] = [
      "kandinskyJobId": job, "kandinskyStatus": running ? "running" : "failed",
      "kandinskyModel": "image", "kandinskyAspect": "1:1",
    ]
    if running { metadata["kandinskyProgress"] = 21 }
    if let slots {
      metadata["kandinskySlots"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slots))
    }
    return try JSONSerialization.data(withJSONObject: [
      "messages": [[
        "id": 52, "chatId": 2, "seq": 301, "senderId": 0, "clientId": job,
        "kind": "text", "text": running ? "Генерация" : "Не удалось создать", "caption": "",
        "savedAtMs": 1_794_483_289_395, "revision": running ? 2 : 1,
        "attachments": [], "metadata": metadata,
      ] as [String: Any]],
    ])
  }

  // Разбирает тело запроса напрямую или считывает переданный поток до конца. Так тест видит
  // отправленные поля независимо от способа их передачи сетевой службой.
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

  // Возвращает условный профиль для местной проверки с узнаваемыми полями. Настоящая учётная
  // запись для этих запросов не требуется.
  private func testProfile() -> NetworkProfile {
    NetworkProfile(userId: 2, deviceId: "local-fixture", name: "Проверка",
                   token: String(repeating: "a", count: 64), expiresAtMs: Int64.max,
                   username: "fixture")
  }
}

final class ScriptedHTTP: URLProtocol, @unchecked Sendable {
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

  // Устанавливает очередь ответов и создаёт временную сетевую сессию с перехватом запросов. Тест
  // не передаёт условные запросы внешнему серверу.
  static func makeAPI(_ replies: [ScriptedHTTP.Reply], profile: NetworkProfile? = nil) -> NetworkAPI {
    configure(replies)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [self]
    configuration.timeoutIntervalForRequest = 3
    return NetworkAPI(profile: profile, transportConfiguration: configuration)
  }

  // Под замком сбрасывает прошлые запросы и задаёт новые ответы. Повторная настройка не оставит
  // следов соседнего теста.
  static func configure(_ replies: [Reply]) {
    script.lock.withLock {
      script.received.removeAll()
      script.replies = replies
    }
  }

  // Возвращает снимок накопленных запросов под замком. Тест может сверять порядок, пока
  // обработчик работает на другом потоке.
  static func requests() -> [URLRequest] { script.lock.withLock { script.received } }

  // Разрешает перехват каждого запроса временной сессии. Без этого часть запросов ушла бы по
  // обычному сетевому пути.
  override class func canInit(with request: URLRequest) -> Bool { true }
  // Возвращает исходный запрос без правок. Тогда проверка видит адрес и параметры, которые
  // действительно собрал клиент.
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  // Запоминает исходный запрос и выдаёт следующий заданный ответ или сбой. При исчерпании ответов
  // сообщает об ошибке, чтобы лишний вызов не прошёл незаметно.
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

  // Завершает отмену без дополнительной работы. Ответ выдаётся сразу, поэтому отдельной загрузки,
  // которую надо остановить, здесь нет.
  override func stopLoading() {}
}
