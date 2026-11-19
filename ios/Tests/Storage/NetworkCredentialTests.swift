// Проверяет хранение ключей входа, восстановление выбранного чата и удаление данных одного
// владельца. Для местных проверок используются отдельные папки и имена хранилища ключей.

import Security
import XCTest
@testable import Kandinsky

final class NetworkCredentialTests: XCTestCase {
  // Сохраняет ключ и выбранный чат, выполняет выход и затем записывает новый ключ. Выход убирает
  // данные входа, а выбранное место можно вернуть после повторного входа.
  func testLogoutKeepsTheOwnersSelectedChatWithoutKeepingCredentials() throws {
    let user = Int64.random(in: 1_000_000...Int64.max)
    let service = "kandinsky.qa.navigation." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer {
      clearTestCredentials(service: service)
      NetworkCredentials.selectChat(nil, for: user)
    }
    let first = NetworkProfile(userId: user, deviceId: "first", name: "Owner",
      token: String(repeating: "c", count: 64), expiresAtMs: 500)
    try store.save(first)
    NetworkCredentials.selectChat(3151, for: user)
    try store.removeActive()
    XCTAssertNil(try store.load())
    XCTAssertTrue(try store.profiles().isEmpty)
    XCTAssertEqual(NetworkCredentials.selectedChat(for: user), 3151)
    let second = NetworkProfile(userId: user, deviceId: "second", name: "Owner",
      token: String(repeating: "d", count: 64), expiresAtMs: 600)
    try store.save(second)
    XCTAssertEqual(try store.load()?.deviceId, "second")
    XCTAssertEqual(NetworkCredentials.selectedChat(for: user), 3151)
  }

  // Убирает профиль по номеру после окончания входа. Проверяет, что ключи исчезли и при этом
  // выбранный чат владельца сохранился.
  func testExpiredSessionKeepsTheOwnersSelectedChatWithoutKeepingCredentials() throws {
    let user = Int64.random(in: 1_000_000...Int64.max)
    let service = "kandinsky.qa.expired." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer {
      clearTestCredentials(service: service)
      NetworkCredentials.selectChat(nil, for: user)
    }
    try store.save(NetworkProfile(userId: user, deviceId: "first", name: "Owner",
      token: String(repeating: "c", count: 64), expiresAtMs: 500))
    NetworkCredentials.selectChat(3151, for: user)
    try store.forget(user)
    XCTAssertNil(try store.load())
    XCTAssertTrue(try store.profiles().isEmpty)
    XCTAssertEqual(NetworkCredentials.selectedChat(for: user), 3151)
  }

  // Запоминает разные чаты у двух владельцев и завершает удаление одного. Проверяет, что
  // выбранный чат и ключ удалённого исчезли, а выбор второго остался.
  func testPermanentErasureClearsOnlyTheDeletedOwnersSelection() throws {
    let user = Int64.random(in: 1_000_000...(Int64.max - 1))
    let other = user + 1
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = "kandinsky.qa.erase-navigation." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer {
      clearTestCredentials(service: service)
      try? FileManager.default.removeItem(at: root)
      NetworkCredentials.selectChat(nil, for: user)
      NetworkCredentials.selectChat(nil, for: other)
    }
    try store.save(NetworkProfile(userId: user, deviceId: "first", name: "Owner",
      token: String(repeating: "c", count: 64), expiresAtMs: 500))
    NetworkCredentials.selectChat(3151, for: user)
    NetworkCredentials.selectChat(4000, for: other)
    try LocalAccountErasure.stage(user, root: root)
    try LocalAccountErasure.finish(root: root, forget: store.forget)
    XCTAssertNil(try store.load())
    XCTAssertTrue(try store.profiles().isEmpty)
    XCTAssertNil(NetworkCredentials.selectedChat(for: user))
    XCTAssertEqual(NetworkCredentials.selectedChat(for: other), 4000)
  }

  // Сохраняет несколько профилей, включая старый без имени для входа, и превышает предел списка.
  // Неверный ключ не должен занять место последнего действительного профиля.
  func testRememberedAccountsRemainBoundedAndPreserveLegacyProfile() throws {
    let service = "kandinsky.qa.credentials." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer { clearTestCredentials(service: service) }
    let legacy = NetworkProfile(
      userId: 1, deviceId: "legacy", name: "Prior invitation",
      token: String(repeating: "a", count: 64), expiresAtMs: 123)
    try store.save(legacy)
    let next = NetworkProfile(
      userId: 1000, deviceId: "new", name: "Demo", token: String(repeating: "b", count: 64),
      expiresAtMs: 456, username: "demo")
    try store.save(next)
    XCTAssertEqual(try store.load()?.userId, 1000)
    XCTAssertEqual(try store.profiles().map(\.userId), [1000, 1])
    try store.save(legacy)
    XCTAssertNil(try store.load()?.username)
    XCTAssertEqual(try store.profiles().count, 2)
    for id in 1001...1010 {
      try store.save(
        NetworkProfile(
          userId: Int64(id), deviceId: "qa", name: "Demo", token: String(repeating: "c", count: 64),
          expiresAtMs: 456))
    }
    XCTAssertEqual(try store.profiles().count, 8)
    XCTAssertThrowsError(
      try store.save(
        NetworkProfile(userId: 1234, deviceId: "bad", name: "Bad", token: "bad", expiresAtMs: 1)))
    XCTAssertEqual(try store.load()?.userId, 1010)
  }
  func testAddingAnotherAccountKeepsTheLegacyActiveRecord() throws {
    let service = "kandinsky.qa.legacy-active." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer { clearTestCredentials(service: service) }
    let old = NetworkProfile(userId: 101, deviceId: "old-device", name: "Первый профиль",
      token: String(repeating: "a", count: 64), expiresAtMs: 500)
    let new = NetworkProfile(userId: 102, deviceId: "new-device", name: "Второй профиль",
      token: String(repeating: "b", count: 64), expiresAtMs: 600)
    try store.save(old)
    let list = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "accounts",
    ] as [String: Any]
    XCTAssertEqual(SecItemDelete(list as CFDictionary), errSecSuccess)
    XCTAssertEqual(try store.load()?.userId, old.userId)

    try store.save(new)
    XCTAssertEqual(try store.load()?.userId, new.userId)
    let profiles = try store.profiles()
    XCTAssertEqual(profiles.map(\.userId), [new.userId, old.userId])
    let recovered = try XCTUnwrap(profiles.last)
    XCTAssertEqual(recovered.token, old.token)
    XCTAssertTrue(String(describing: recovered).contains(String(old.userId)))
    XCTAssertFalse(String(describing: recovered).contains(old.token))
    try store.save(recovered)
    XCTAssertEqual(try store.load()?.userId, old.userId)
  }

  // Сверяет отметку резервного копирования, уборку старых временных файлов и свойства ключей в
  // системном хранилище. Так можно обнаружить утечку ключей в копию или удаление файла активной
  // подготовки.
  func testAccountFilesAreExcludedFromBackupAndCredentialsStayOnThisDevice() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = try AppDataRoot.resolve(base)
    let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
    let account = root.appendingPathComponent("net-v1-u5")
    let active = try AttachmentScratch.file(in: account, extension: "jpg")
    try Data([42]).write(to: active)
    let old = active.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("previous-run")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try Data([42]).write(to: old.appendingPathComponent("capture.jpg"))
    try AttachmentScratch.removePreviousRuns(in: account)
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    let service = "kandinsky.qa.backup." + UUID().uuidString
    let store = NetworkCredentialStore(service: service)
    defer { clearTestCredentials(service: service) }
    try store.save(NetworkProfile(userId: 5, deviceId: "test", name: "test",
      token: String(repeating: "c", count: 64), expiresAtMs: 123))
    for account in ["device", "accounts"] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account, kSecReturnAttributes as String: true
      ]
      var result: CFTypeRef?
      XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
      let attributes = try XCTUnwrap(result as? [String: Any])
      XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
    try store.removeActive()
    XCTAssertNil(try store.load())
    XCTAssertTrue(try store.profiles().isEmpty)
  }

  // По явному разрешению обращается к защищённому адресу без ключа и ждёт отказ сервера. Ответ
  // подтверждает установку защищённого соединения и требование входа на этом маршруте.
  func testReleaseClientReachesProtectedRouteOverTLS() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["KANDINSKY_VERIFY_LIVE_TLS"] == "1")
    let api = NetworkAPI(profile: nil)
    defer { api.close() }
    do {
      _ = try await api.json("/v1/kandinsky/activity", method: "POST")
      XCTFail("The server accepted a request without credentials")
    } catch let error as NetworkFailure {
      XCTAssertEqual(error.status, 401)
    }
  }

  // Читает сохранённый профиль прежнего вида без имени для входа. Старый аккаунт остаётся
  // читаемым, а новое поле остаётся пустым.
  func testOldSessionJSONWithoutUsernameRemainsReadable() throws {
    let data = Data(
      """
      {
        "userId": 1,
        "deviceId": "legacy",
        "name": "Existing",
        "token": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "expiresAtMs": 123
      }
      """
        .utf8)
    let profile = try JSONDecoder().decode(NetworkProfile.self, from: data)
    XCTAssertEqual(profile.userId, 1)
    XCTAssertNil(profile.username)
  }
  // Создаёт соседние папки и прерывает очистку искусственной ошибкой, затем повторяет её.
  // Проверяет исчезновение только выбранной папки и сохранение профиля второго аккаунта.
  func testErasureResumesFromDiskAndPreservesTheOtherAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = "kandinsky.qa.erasure." + UUID().uuidString
    let credentials = NetworkCredentialStore(service: service)
    defer { clearTestCredentials(service: service) }
    for id: Int64 in [9, 11] {
      let directory = root.appendingPathComponent("net-v1-u\(id)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data([42]).write(to: directory.appendingPathComponent("history"))
      try credentials.save(
        NetworkProfile(
          userId: id, deviceId: "fixture", name: "Fixture",
          token: String(repeating: "a", count: 64), expiresAtMs: 123))
    }
    try LocalAccountErasure.stage(9, root: root)
    XCTAssertThrowsError(try LocalAccountErasure.finish(root: root) { _ in throw RepoError.io })
    try LocalAccountErasure.finish(root: root, forget: credentials.forget)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("net-v1-u9").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("net-v1-u11/history").path)
    )
    XCTAssertEqual(try credentials.load()?.userId, 11)
    XCTAssertEqual(try credentials.profiles().map(\.userId), [11])
    try LocalAccountErasure.finish(root: root, forget: credentials.forget)
  }

  // Убирает записи только по отдельному имени временного хранилища. Проверка признаёт отсутствие
  // записей нормальным, чтобы уборку можно было провести повторно.
  private func clearTestCredentials(service: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service
    ]
    let status = SecItemDelete(query as CFDictionary)
    XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
  }
}
