import UIKit
import XCTest
@testable import Kandinsky

private final class RecordingAccountService: AccountEntryService {
  var calls: [String] = []
  var signInError: Error?
  var closeCount = 0
  let profile = NetworkProfile(userId: 1, deviceId: "phone", name: "reader", token: "token", expiresAtMs: 0)
  func requestEmailCode(email: String, recovery: Bool) async throws {
    calls.append(recovery ? "recover" : "register")
  }
  func resetPassword(email: String, code: String, password: String) async throws {
    calls.append("reset " + code)
  }
  func signIn(email: String, password: String, registrationCode: String?) async throws -> NetworkProfile {
    calls.append(registrationCode ?? "login")
    if let signInError { throw signInError }
    return profile
  }
  func close() { closeCount += 1 }
}

@MainActor final class AccountEntryViewModelTests: XCTestCase {
  private func submit(_ model: AccountEntryViewModel, code: String = "", resending: Bool = false) async {
    let done = expectation(description: "Форма приняла ответ")
    model.onChange = { if !model.isBusy { done.fulfill() } }
    model.submit(email: " reader@example.org ", password: "example password", code: code, resending: resending)
    await fulfillment(of: [done], timeout: 3)
    model.onChange = nil
  }

  func testRecoveryAndRegistrationKeepDifferentPurposes() async {
    let service = RecordingAccountService()
    var saved: [Int64] = []
    let model = AccountEntryViewModel(api: service, loadProfiles: { [] }, saveProfile: { saved.append($0.userId) })
    model.onSelection = { profile in XCTAssertEqual(saved.last, profile.userId) }
    model.startRecovery()
    await submit(model)
    XCTAssertEqual(model.step, .verifyRecovery)
    await submit(model, resending: true)
    await submit(model, code: "123x5678")
    XCTAssertEqual(service.calls, ["recover", "recover"])
    await submit(model, code: "01234567")
    XCTAssertEqual(model.step, .login)
    XCTAssertTrue(saved.isEmpty)
    await submit(model)
    model.toggleRegistration()
    await submit(model)
    XCTAssertEqual(model.step, .verifyRegistration)
    await submit(model, code: "87654321")
    XCTAssertEqual(service.calls, ["recover", "recover", "reset 01234567", "login", "register", "87654321"])
    XCTAssertEqual(saved, [1, 1])
  }

  func testDuplicateSubmissionAndClosedScreenDoNotSaveProfile() async {
    let service = RecordingAccountService()
    var saved = false
    let model = AccountEntryViewModel(api: service, loadProfiles: { [] }, saveProfile: { _ in saved = true })
    model.submit(email: "reader@example.org", password: "example password", code: "")
    model.submit(email: "reader@example.org", password: "example password", code: "")
    XCTAssertTrue(model.isBusy)
    model.close()
    await Task.yield()
    await Task.yield()
    XCTAssertLessThanOrEqual(service.calls.count, 1)
    XCTAssertFalse(saved)
  }

  func testInvalidInputKeepsTheLoginFormAndNeverUsesTheNetwork() {
    let service = RecordingAccountService()
    let model = AccountEntryViewModel(api: service, loadProfiles: { [] }, saveProfile: { _ in })
    model.submit(email: "reader", password: "valid-password", code: "")
    XCTAssertEqual(model.message, "Введите электронную почту.")
    model.submit(email: "reader@example.org", password: "short", code: "")
    XCTAssertEqual(model.message, "Введите пароль длиной от 12 до 128 символов.")
    XCTAssertFalse(model.isBusy)
    XCTAssertTrue(service.calls.isEmpty)
    XCTAssertEqual(model.step, .login)
  }

  func testFailedLoginShowsActionableMessageAndNeverSavesSession() async {
    let service = RecordingAccountService()
    let model = AccountEntryViewModel(api: service, loadProfiles: { [] }, saveProfile: { _ in
      XCTFail("Неудачный вход не создаёт сеанс")
    })
    model.onSelection = { _ in XCTFail("Неудачный вход не меняет аккаунт") }
    let failures = [
      (400, "Код неверный или больше не действует."),
      (401, "Неверная почта или пароль."),
      (409, "Аккаунт уже существует. Войдите с паролем."),
      (422, "Выберите другой пароль."),
      (429, "Слишком много попыток. Попробуйте через минуту."),
      (503, "Служба временно недоступна. Попробуйте ещё раз."),
      (500, "Не удалось выполнить запрос.")
    ]
    for (status, message) in failures {
      service.signInError = NetworkFailure(status: status, code: "Выберите другой пароль.")
      await submit(model)
      XCTAssertEqual(model.message, message, "HTTP \(status)")
      XCTAssertEqual(model.step, .login)
    }
    service.signInError = URLError(.notConnectedToInternet)
    await submit(model)
    XCTAssertEqual(model.message, "Проверьте соединение и попробуйте снова.")
    XCTAssertEqual(service.calls, Array(repeating: "login", count: failures.count + 1))
  }

  func testUnreadableOrUnsavableProfileNeverReplacesTheCurrentAccount() {
    let service = RecordingAccountService()
    let storageError = CocoaError(.fileReadNoPermission)
    var failReading = true
    var failSaving = true
    let model = AccountEntryViewModel(api: service, loadProfiles: {
      if failReading { throw storageError }
      return [service.profile]
    }, saveProfile: { _ in
      if failSaving { throw storageError }
    })
    XCTAssertTrue(model.savedProfiles().isEmpty)
    XCTAssertEqual(model.message, "Не удалось прочитать сохранённые аккаунты. Данные остаются на устройстве.")
    failReading = false
    XCTAssertEqual(model.savedProfiles().map(\.userId), [service.profile.userId])

    var selected: [Int64] = []
    model.onSelection = { selected.append($0.userId) }
    model.choose(service.profile)
    XCTAssertEqual(model.message, "Не удалось сохранить вход на устройстве.")
    XCTAssertTrue(selected.isEmpty)
    failSaving = false
    model.choose(service.profile)
    XCTAssertEqual(selected, [service.profile.userId])
    model.close()
    model.choose(service.profile)
    XCTAssertEqual(selected, [service.profile.userId])
    XCTAssertEqual(service.closeCount, 1)
  }
}


@MainActor final class AccountEntryControllerTests: XCTestCase {
  private func component<T: UIView>(_ id: String, in root: UIView, as type: T.Type) throws -> T {
    func find(_ view: UIView) -> T? {
      if view.accessibilityIdentifier == id { return view as? T }
      for child in view.subviews {
        if let match = find(child) { return match }
      }
      return nil
    }
    return try XCTUnwrap(find(root), id)
  }

  func testLoginScreenValidatesInputAndResetsPasswordWhenChangingSteps() throws {
    let controller = AccountEntryController(api: NetworkAPI(profile: nil))
    var cancelled = false
    controller.cancelled = { cancelled = true }
    controller.selected = { _ in XCTFail("Неверный ввод не меняет аккаунт") }
    defer { controller.close() }
    controller.loadViewIfNeeded()

    let screen = try XCTUnwrap(controller.view)
    let email = try component("account.username", in: screen, as: UITextField.self)
    let password = try component("account.name", in: screen, as: UITextField.self)
    let code = try component("account.code", in: screen, as: UITextField.self)
    let submit = try component("account.submit", in: screen, as: UIButton.self)
    let toggle = try component("account.toggle", in: screen, as: UIButton.self)
    let forgot = try component("account.forgot", in: screen, as: UIButton.self)
    let error = try component("account.error", in: screen, as: UILabel.self)
    let visibility = try XCTUnwrap(password.rightView as? UIButton)

    XCTAssertTrue(password.isSecureTextEntry)
    XCTAssertTrue(code.isHidden)
    email.text = "reader"
    password.text = "local-test-password"
    visibility.sendActions(for: .touchUpInside)
    XCTAssertFalse(password.isSecureTextEntry)
    XCTAssertEqual(password.text, "local-test-password")
    visibility.sendActions(for: .touchUpInside)
    XCTAssertTrue(password.isSecureTextEntry)
    submit.sendActions(for: .touchUpInside)
    XCTAssertEqual(error.text, "Введите электронную почту.")

    toggle.sendActions(for: .touchUpInside)
    XCTAssertEqual(submit.currentTitle, "Получить код")
    XCTAssertTrue(password.isHidden)
    XCTAssertTrue(password.text?.isEmpty ?? false)
    XCTAssertTrue(forgot.isHidden)
    XCTAssertNil(error.text)
    toggle.sendActions(for: .touchUpInside)
    XCTAssertFalse(password.isHidden)
    XCTAssertFalse(forgot.isHidden)

    forgot.sendActions(for: .touchUpInside)
    XCTAssertEqual(submit.currentTitle, "Получить код")
    XCTAssertTrue(password.isHidden)
    XCTAssertTrue(code.isHidden)

    let cancel = try component("account.cancel", in: screen, as: UIButton.self)
    cancel.sendActions(for: .touchUpInside)
    XCTAssertTrue(cancelled)
  }
}
