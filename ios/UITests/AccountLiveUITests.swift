// Проверяет открытие двух исходных историй на айфоне через обычный список. Использует уже
// открытый проверочный вход.

import XCTest

final class AccountLiveUITests: XCTestCase {
  // Запускает приложение и по очереди открывает обе истории по названию. Ждёт поле ввода после
  // каждого нажатия, а без готового входа пропускает проверку.
  func testAccountCanOpenBothOriginalHistories() throws {
    let app = XCUIApplication()
    app.launch()
    let menu = app.buttons["chat.back"]
    guard menu.waitForExistence(timeout: 10) else {
      throw XCTSkip("Для просмотра истории нужен вход в существующий аккаунт")
    }
    for title in ["Плотная медиалента", "Длинная история"] {
      menu.tap()
      let row = app.buttons.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", title
        )
      ).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      row.tap()
      XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 10))
    }
  }

  func testColdLaunchAcceptsOnlyTheInvitationHost() throws {
    let environment = ProcessInfo.processInfo.environment
    guard #available(iOS 16.4, *), let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1"
    else { throw XCTSkip("Нужны местный сервер и симулятор со входом по ссылке") }
    continueAfterFailure = false
    let app = XCUIApplication()
    let username = app.textFields["account.username"]
    let composer = app.textViews["composer.input"]
    let token = String(repeating: "0", count: 64)
    let wrong = try XCTUnwrap(URL(string: "kandinsky-native://other?invitation=" + token))
    app.open(wrong)
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    XCTAssertFalse(composer.exists)

    let invitation = try XCTUnwrap(URL(string: "kandinsky-native://join?invitation=" + token))
    app.open(invitation)
    let refusal = app.staticTexts["Не удалось подключиться к Кандинскому (401)."]
    XCTAssertTrue(refusal.waitForExistence(timeout: 8))
    XCTAssertFalse(username.exists)

    app.terminate()
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    XCTAssertFalse(app.textViews["composer.input"].exists)
  }

  func testValidInvitationsOpenTheNativeAccountFromALinkAndALaunchArgument() throws {
    let environment = ProcessInfo.processInfo.environment
    guard #available(iOS 16.4, *),
      environment["KANDINSKY_TEST_ORIGIN"] == "https://127.0.0.1:54989",
      let linkKey = environment["KANDINSKY_TEST_VALID_INVITATION"],
      let launchKey = environment["KANDINSKY_TEST_LAUNCH_INVITATION"],
      linkKey != launchKey
    else { throw XCTSkip("Нужны два действующих ключа местного проверочного аккаунта") }

    continueAfterFailure = false
    let app = XCUIApplication()
    let username = app.textFields["account.username"]
    let menu = app.buttons["chat.back"]
    let composer = app.textViews["composer.input"]
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 10))

    func openHistory(_ title: String) {
      XCTAssertTrue(menu.waitForExistence(timeout: 12))
      menu.tap()
      let chat = app.buttons.matching(NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", title
      )).firstMatch
      XCTAssertTrue(chat.waitForExistence(timeout: 10))
      chat.tap()
      XCTAssertTrue(composer.waitForExistence(timeout: 10))
    }

    func signOut() {
      menu.tap()
      app.buttons["chats.account"].tap()
      XCTAssertTrue(username.waitForExistence(timeout: 15))
    }

    let link = try XCTUnwrap(URL(string: "kandinsky-native://join?invitation=" + linkKey))
    app.open(link)
    openHistory("Плотная медиалента")
    signOut()
    app.terminate()
    app.launchArguments = ["--network-invitation", launchKey]
    app.launch()
    openHistory("Длинная история")
    signOut()
    app.launchArguments = []
  }

  func testLocalSignInSurvivesRestartAndSignOutClearsTheSession() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      let email = environment["KANDINSKY_TEST_EMAIL"],
      let password = environment["KANDINSKY_TEST_PASSWORD"]
    else { throw XCTSkip("Нужна отдельная местная установка с проверочным входом") }

    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10), "Тест начинается с пустой установки")
    submitLogin(email: email, password: password, in: app)
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)

    app.terminate()
    app.launch()
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    let menu = app.buttons["chat.back"]
    menu.tap()
    let thread = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", "Плотная медиалента")
    ).firstMatch
    XCTAssertTrue(thread.waitForExistence(timeout: 10))
    thread.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))

    menu.tap()
    let signOut = app.buttons["chats.account"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 5))
    signOut.tap()
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    XCTAssertFalse(composer.exists)
  }


  func testLocalAccountRemovalRejectsWrongPasswordAndClearsAccess() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      let email = environment["KANDINSKY_TEST_ERASURE_EMAIL"],
      email.hasPrefix("native-coverage-delete-ios-"), email.hasSuffix("@example.com"),
      let password = environment["KANDINSKY_TEST_ERASURE_PASSWORD"]
    else { throw XCTSkip("Для удаления нужен отдельный временный аккаунт на местном сервере") }

    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10), "Тест начинается с пустой установки")
    submitLogin(email: email, password: password, in: app)
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)

    func openErasure() {
      let drawer = app.buttons["chat.back"]
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "hittable == true"), object: drawer)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
      drawer.tap()
      let manage = app.buttons["chats.manageAccount"]
      XCTAssertTrue(manage.waitForExistence(timeout: 8))
      manage.tap()
      let remove = app.descendants(matching: .any).matching(
        NSPredicate(format: "label == %@", "Удалить аккаунт")
      ).firstMatch
      XCTAssertTrue(remove.waitForExistence(timeout: 8))
      remove.tap()
    }

    openErasure()
    let prompt = app.alerts["Удалить аккаунт?"]
    let secret = prompt.secureTextFields["account.erasure.password"]
    let confirm = prompt.buttons["Удалить навсегда"]
    XCTAssertTrue(secret.waitForExistence(timeout: 8))
    XCTAssertFalse(confirm.isEnabled)
    secret.tap()
    secret.typeText("WrongPassword2026")
    XCTAssertTrue(confirm.isEnabled)
    confirm.tap()

    let rejected = app.alerts["Удаление аккаунта"]
    XCTAssertTrue(rejected.staticTexts["Неверный пароль."].waitForExistence(timeout: 12))
    rejected.buttons["Понятно"].tap()
    XCTAssertTrue(composer.exists)

    openErasure()
    XCTAssertTrue(secret.waitForExistence(timeout: 8))
    secret.tap()
    secret.typeText(password)
    confirm.tap()
    XCTAssertTrue(username.waitForExistence(timeout: 20))
    app.terminate()
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    submitLogin(email: email, password: password, in: app)
    let feedback = app.staticTexts["account.error"]
    XCTAssertTrue(feedback.waitForExistence(timeout: 12))
    XCTAssertFalse(feedback.label.isEmpty)
    XCTAssertFalse(composer.exists)
  }

  @MainActor
  func testLocalRegistrationAndRecoveryUseCodesFromSeparateLetters() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      environment["KANDINSKY_TEST_MAILBOX"] == "1"
    else { throw XCTSkip("Нужна местная почта проверочного сервера") }

    continueAfterFailure = false
    let mail = "native-coverage-flow-ios-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    let originalPassword = "FirstLocalPassword2026!"
    let recoveredPassword = "RecoveredLocalPassword2026!"
    let app = XCUIApplication()
    app.launch()
    let email = app.textFields["account.username"]
    let code = app.textFields["account.code"]
    let password = app.secureTextFields["account.name"]
    let submit = app.buttons["account.submit"]
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(email.waitForExistence(timeout: 10))

    app.buttons["account.toggle"].tap()
    email.tap()
    email.typeText(mail)
    XCTAssertEqual(submit.label, "Получить код")
    submit.tap()
    XCTAssertTrue(code.waitForExistence(timeout: 12))
    XCTAssertFalse(email.isEnabled)
    XCTAssertEqual(submit.label, "Зарегистрироваться")
    let registrationCode = try await localMailCode("registration", email: mail, origin: origin)
    code.tap()
    code.typeText(registrationCode)
    fillNewPassword(originalPassword, in: app)
    submit.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)

    app.buttons["chat.back"].tap()
    let exit = app.buttons["chats.account"]
    XCTAssertTrue(exit.waitForExistence(timeout: 8))
    exit.tap()
    XCTAssertTrue(email.waitForExistence(timeout: 12))
    app.buttons["account.forgot"].tap()
    email.tap()
    email.typeText(mail)
    XCTAssertEqual(submit.label, "Получить код")
    submit.tap()
    XCTAssertTrue(code.waitForExistence(timeout: 12))
    XCTAssertEqual(submit.label, "Сохранить пароль")
    let recoveryCode = try await localMailCode("recovery", email: mail, origin: origin)
    code.tap()
    code.typeText(recoveryCode)
    fillNewPassword(recoveredPassword, in: app)
    submit.tap()
    XCTAssertTrue(app.staticTexts["Пароль изменён. Войдите с новым паролем."]
      .waitForExistence(timeout: 12))

    password.tap()
    password.typeText(originalPassword)
    submit.tap()
    let rejected = app.staticTexts["Неверная почта или пароль."]
    XCTAssertTrue(rejected.waitForExistence(timeout: 12))

    password.tap()
    password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalPassword.count))
    password.typeText(recoveredPassword)
    submit.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    app.buttons["chat.back"].tap()
    XCTAssertTrue(exit.waitForExistence(timeout: 8))
    exit.tap()
    XCTAssertTrue(email.waitForExistence(timeout: 12))
  }

  @MainActor
  func testPasswordResetRevokesTheActiveSessionAndKeepsItsDraft() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      environment["KANDINSKY_TEST_MAILBOX"] == "1"
    else { throw XCTSkip("Нужна местная почта проверочного сервера") }
    continueAfterFailure = false
    let nonce = UUID().uuidString.prefix(8).lowercased()
    let email = "native-coverage-flow-ios-\(nonce)@example.com"
    let oldPassword = "NativeFirst-\(nonce)!"
    let newPassword = "NativeReset-\(nonce)!"
    try await registerFixture(email: email, password: oldPassword, origin: origin)

    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    submitLogin(email: email, password: oldPassword, in: app)
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    let draft = "Черновик перед отзывом сеанса"
    composer.tap()
    composer.typeText(draft)
    XCTAssertEqual(composer.value as? String, draft)

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    try await fixtureJSON("/v1/demo/password-reset/request", origin: origin, fields: ["email": email])
    let code = try await localMailCode("recovery", email: email, origin: origin)
    try await fixtureJSON("/v1/demo/password-reset/confirm", origin: origin, fields: [
      "email": email, "code": code, "password": newPassword,
    ])
    app.activate()
    XCTAssertTrue(username.waitForExistence(timeout: 20))
    XCTAssertFalse(composer.exists)
    submitLogin(email: email, password: newPassword, in: app)
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    XCTAssertEqual(composer.value as? String, draft)

    app.buttons["chat.back"].tap()
    let exit = app.buttons["chats.account"]
    XCTAssertTrue(exit.waitForExistence(timeout: 8))
    exit.tap()
    XCTAssertTrue(username.waitForExistence(timeout: 12))
  }

  @MainActor
  func testErasingTheAccountFromAnotherSessionClosesTheOpenStudio() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      environment["KANDINSKY_TEST_MAILBOX"] == "1"
    else { throw XCTSkip("Для удаления нужен отдельный местный сервер") }
    continueAfterFailure = false
    let nonce = UUID().uuidString.prefix(8).lowercased()
    let email = "native-coverage-flow-ios-\(nonce)@example.com"
    let password = "OtherSession-\(nonce)!"
    try await registerFixture(email: email, password: password, origin: origin)
    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["account.username"]
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    submitLogin(email: email, password: password, in: app)
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    composer.tap()
    composer.typeText("Черновик удаляемого проверочного аккаунта")

    let login = try await fixtureJSON("/v1/demo/login", origin: origin, fields: [
      "email": email, "password": password,
    ])
    struct Profile: Decodable {
      let userId: Int64
      let token: String
    }
    let second = try JSONDecoder().decode(Profile.self, from: login)
    let blockedRoot = try localErasureRoot(environment)
    let manager = FileManager.default
    let queue = blockedRoot?.appendingPathComponent("erased-accounts", isDirectory: true)
    let owner = blockedRoot?.appendingPathComponent("net-v1-u\(second.userId)", isDirectory: true)
    let backup = blockedRoot?.appendingPathComponent("erased-accounts-coverage-\(nonce)")
    var moved = false
    let obstruction = Data("fixture-\(nonce)".utf8)
    func restoreQueue() throws {
      if let queue, (try? Data(contentsOf: queue)) == obstruction {
        try manager.removeItem(at: queue)
      }
      if moved, let backup, let queue {
        try manager.moveItem(at: backup, to: queue)
        moved = false
      }
    }
    defer { try? restoreQueue() }
    if let owner, let queue, let backup {
      XCTAssertTrue(manager.fileExists(atPath: owner.appendingPathComponent("chat.sqlite3").path))
      if manager.fileExists(atPath: queue.path) {
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: queue.path).isEmpty)
        try manager.moveItem(at: queue, to: backup)
        moved = true
      }
      try obstruction.write(to: queue, options: .withoutOverwriting)
    }
    try await fixtureJSON(
      "/v1/kandinsky/account", origin: origin, method: "DELETE",
      fields: ["password": password], bearer: second.token)
    if let owner {
      let failure = app.alerts["Не удалось очистить данные"]
      XCTAssertTrue(failure.waitForExistence(timeout: 22))
      XCTAssertTrue(manager.fileExists(atPath: owner.path))
      try restoreQueue()
      failure.buttons["Повторить"].tap()
    }
    XCTAssertTrue(username.waitForExistence(timeout: 22))
    if let owner { XCTAssertFalse(manager.fileExists(atPath: owner.path)) }
    XCTAssertFalse(composer.exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(username.waitForExistence(timeout: 10))
    XCTAssertFalse(composer.exists)
  }

  @MainActor
  func testLongVideoKeepsTheUnsentDraftAndShowsTheLimit() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let origin = environment["KANDINSKY_TEST_ORIGIN"],
      URLComponents(string: origin)?.host == "127.0.0.1",
      environment["KANDINSKY_TEST_MAILBOX"] == "1",
      environment["KANDINSKY_TEST_LONG_VIDEO"] == "1"
    else { throw XCTSkip("Нужен местный сервер и ролик длительностью больше минуты в галерее") }
    continueAfterFailure = false
    let nonce = UUID().uuidString.prefix(8).lowercased()
    let email = "native-coverage-flow-ios-\(nonce)@example.com"
    let password = "LocalLongVideo-\(nonce)!"
    try await registerFixture(email: email, password: password, origin: origin)
    let app = XCUIApplication()
    app.launch()
    let username = app.textFields["account.username"]
    if !username.waitForExistence(timeout: 3) {
      let exit = app.buttons["chats.account"]
      if !exit.exists { app.buttons["chat.back"].tap() }
      XCTAssertTrue(exit.waitForExistence(timeout: 8))
      exit.tap()
    }
    XCTAssertTrue(username.waitForExistence(timeout: 12))
    submitLogin(email: email, password: password, in: app)
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    dismissSystemPasswordSuggestion(in: app)
    let welcome = app.buttons["chat.welcome"]
    if !welcome.exists {
      app.buttons["chat.back"].tap()
      let compose = app.buttons["chats.compose"]
      XCTAssertTrue(compose.waitForExistence(timeout: 8))
      compose.tap()
    }
    XCTAssertTrue(welcome.waitForExistence(timeout: 10))
    let prompt = "Keep this unfinished request"
    composer.tap()
    composer.typeText(prompt)
    app.buttons["composer.plus"].tap()
    let source = app.buttons.matching(NSPredicate(
      format: "label BEGINSWITH %@", "Загрузить и посмотреть видео")).firstMatch
    XCTAssertTrue(source.waitForExistence(timeout: 8))
    source.tap()
    let video = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Video,"))
    XCTAssertTrue(video.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(video.count, 1)
    let frame = video.firstMatch.frame
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()

    let warning = app.staticTexts["studio.attachment.error"]
    XCTAssertTrue(warning.waitForExistence(timeout: 15))
    XCTAssertEqual(warning.label, "Выберите MP4 до 20 МБ и 60 секунд")
    XCTAssertFalse(app.buttons["studio.upload.expand"].exists)
    XCTAssertFalse(app.buttons["studio.reference.remove"].exists)
    XCTAssertEqual(composer.value as? String, prompt)
    XCTAssertTrue(app.buttons["composer.plus"].isEnabled)

    let login = try await fixtureJSON("/v1/demo/login", origin: origin, fields: [
      "email": email, "password": password,
    ])
    struct Profile: Decodable { let token: String }
    let fixture = try JSONDecoder().decode(Profile.self, from: login)
    try await fixtureJSON(
      "/v1/kandinsky/account", origin: origin, method: "DELETE",
      fields: ["password": password], bearer: fixture.token)
    XCTAssertTrue(username.waitForExistence(timeout: 22))
  }

  // Во время установки система может выдать приложению новый контейнер. Ищем его по
  // идентификатору пакета внутри папки выбранного симулятора.
  private func localErasureRoot(_ environment: [String: String]) throws -> URL? {
    #if targetEnvironment(simulator)
      guard let path = environment["KANDINSKY_TEST_DATA_CONTAINERS"] else { return nil }
      let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
      guard let simulatorID = environment["SIMULATOR_UDID"],
        Array(directory.pathComponents.suffix(5)) ==
          [simulatorID, "data", "Containers", "Data", "Application"]
      else { throw CocoaError(.fileReadInvalidFileName) }
      let candidates = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
      let container = try XCTUnwrap(candidates.first { candidate in
        guard UUID(uuidString: candidate.lastPathComponent) != nil,
          (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
          let metadata = try? Data(contentsOf: candidate.appendingPathComponent(
            ".com.apple.mobile_container_manager.metadata.plist")),
          let properties = try? PropertyListSerialization.propertyList(
            from: metadata, options: [], format: nil) as? [String: Any]
        else { return false }
        return properties["MCMMetadataIdentifier"] as? String == "dev.kirill.kandinsky.native"
      })
      return container.appendingPathComponent("Library/Application Support/Kandinsky")
    #else
      return nil
    #endif
  }

  private func registerFixture(email: String, password: String, origin: String) async throws {
    try await fixtureJSON("/v1/demo/register/request", origin: origin, fields: ["email": email])
    let code = try await localMailCode("registration", email: email, origin: origin)
    try await fixtureJSON("/v1/demo/register", origin: origin, fields: [
      "email": email, "password": password, "code": code,
    ])
  }

  @discardableResult
  private func fixtureJSON(
    _ path: String, origin: String, method: String = "POST",
    fields: [String: String], bearer: String? = nil
  ) async throws -> Data {
    let server = try XCTUnwrap(URL(string: origin))
    let url = try XCTUnwrap(URL(string: path, relativeTo: server)?.absoluteURL)
    guard url.scheme == "https", url.host == "127.0.0.1" else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONEncoder().encode(fields)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    XCTAssertTrue((200..<300).contains(status), "Запрос \(path) вернул код \(status)")
    return data
  }

  private func fillNewPassword(_ password: String, in app: XCUIApplication) {
    let visibility = app.buttons["account.passwordVisibility"]
    XCTAssertTrue(visibility.waitForExistence(timeout: 8))
    visibility.tap()
    let field = app.textFields["account.name"]
    XCTAssertTrue(field.waitForExistence(timeout: 8))
    field.tap()
    field.typeText(password)
    XCTAssertEqual(field.value as? String, password)
    visibility.tap()
  }

  private func localMailCode(_ kind: String, email: String, origin: String) async throws -> String {
    var address = try XCTUnwrap(URLComponents(string: origin))
    address.path = "/v1/__coverage/mail/\(kind)"
    address.queryItems = [URLQueryItem(name: "email", value: email)]
    let (data, response) = try await URLSession.shared.data(from: XCTUnwrap(address.url))
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let body = try JSONDecoder().decode([String: String].self, from: data)
    let code = try XCTUnwrap(body["code"])
    XCTAssertEqual(code.count, 8)
    return code
  }

  private func dismissSystemPasswordSuggestion(in app: XCUIApplication) {
    let suggestion = app.sheets.matching(NSPredicate(format: "label IN %@",
      ["Save Password?", "Update Password?", "Сохранить пароль?", "Обновить пароль?"])).firstMatch
    let skip = suggestion.buttons.matching(
      NSPredicate(format: "label IN %@", ["Not Now", "Не сейчас"])).firstMatch
    guard skip.waitForExistence(timeout: 3) else { return }
    skip.tap()
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: suggestion)
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed)
  }

  private func submitLogin(email: String, password: String, in app: XCUIApplication) {
    let username = app.textFields["account.username"]
    username.tap()
    username.typeText(email)
    let secret = app.secureTextFields["account.name"]
    secret.tap()
    secret.typeText(password)
    app.buttons["account.submit"].tap()
  }
}
