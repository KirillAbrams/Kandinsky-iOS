import Foundation

enum AccountEntryStep {
  case login, registration, recovery, verifyRegistration, verifyRecovery

  var needsCode: Bool { self == .verifyRegistration || self == .verifyRecovery }
  var needsPassword: Bool { self == .login || needsCode }
}

protocol AccountEntryService: AnyObject {
  func requestEmailCode(email: String, recovery: Bool) async throws
  func resetPassword(email: String, code: String, password: String) async throws
  func signIn(email: String, password: String, registrationCode: String?) async throws -> NetworkProfile
  func close()
}

extension NetworkAPI: AccountEntryService {}

@MainActor final class AccountEntryViewModel {
  private let api: AccountEntryService
  private let loadProfiles: () throws -> [NetworkProfile]
  private let saveProfile: (NetworkProfile) throws -> Void
  private var request: Task<Void, Never>?
  private var closed = false
  private(set) var step = AccountEntryStep.login
  private(set) var message: String?
  var isBusy: Bool { request != nil }
  var onChange: (() -> Void)?
  var onSelection: ((NetworkProfile) -> Void)?

  init(api: AccountEntryService,
       loadProfiles: @escaping () throws -> [NetworkProfile] = NetworkCredentials.profiles,
       saveProfile: @escaping (NetworkProfile) throws -> Void = NetworkCredentials.save) {
    self.api = api
    self.loadProfiles = loadProfiles
    self.saveProfile = saveProfile
  }

  func savedProfiles() -> [NetworkProfile] {
    do { return try loadProfiles() } catch {
      message = "Не удалось прочитать сохранённые аккаунты. Данные остаются на устройстве."
      return []
    }
  }

  func choose(_ profile: NetworkProfile) {
    guard !closed, !isBusy else { return }
    do {
      try saveProfile(profile)
      onSelection?(profile)
    } catch { show("Не удалось сохранить вход на устройстве.") }
  }

  func toggleRegistration() {
    guard !closed, !isBusy else { return }
    changeStep(step == .login ? .registration : .login)
  }

  func startRecovery() {
    guard !closed, !isBusy else { return }
    changeStep(.recovery)
  }

  private func changeStep(_ next: AccountEntryStep, message: String? = nil) {
    step = next
    show(message)
  }

  private func show(_ text: String?) {
    message = text
    onChange?()
  }

  func submit(email: String, password: String, code: String, resending: Bool = false) {
    guard !closed, !isBusy else { return }
    let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard email.contains("@") else { return show("Введите электронную почту.") }
    if !resending && step.needsCode && (code.utf8.count != 8 || !code.utf8.allSatisfy({ (48...57).contains($0) })) {
      return show("Введите восемь цифр из письма.")
    }
    if !resending && step.needsPassword && !(12...128).contains(password.count) {
      return show("Введите пароль длиной от 12 до 128 символов.")
    }

    let action = step
    let api = self.api
    request = Task { [weak self] in
      defer {
        self?.request = nil
        self?.onChange?()
      }
      do {
        if resending || !action.needsPassword {
          let recovery = action == .recovery || action == .verifyRecovery
          try await api.requestEmailCode(email: email, recovery: recovery)
          try Task.checkCancellation()
          let notice = recovery ? "Если аккаунт есть, код придёт на почту." : "Если адрес свободен, код придёт на почту."
          if resending { self?.show(notice) }
          else { self?.changeStep(recovery ? .verifyRecovery : .verifyRegistration, message: notice) }
        } else if action == .verifyRecovery {
          try await api.resetPassword(email: email, code: code, password: password)
          try Task.checkCancellation()
          self?.changeStep(.login, message: "Пароль изменён. Войдите с новым паролем.")
        } else {
          let registrationCode = action == .verifyRegistration ? code : nil
          let profile = try await api.signIn(email: email, password: password, registrationCode: registrationCode)
          try Task.checkCancellation()
          try self?.saveProfile(profile)
          self?.onSelection?(profile)
        }
      } catch {
        if !Task.isCancelled { self?.show(Self.message(for: error)) }
      }
    }
    show(nil)
  }

  private static func message(for error: Error) -> String {
    guard let failure = error as? NetworkFailure else { return "Проверьте соединение и попробуйте снова." }
    switch failure.status {
    case 400: return "Код неверный или больше не действует."
    case 401: return "Неверная почта или пароль."
    case 409: return "Аккаунт уже существует. Войдите с паролем."
    case 422: return failure.code
    case 429: return "Слишком много попыток. Попробуйте через минуту."
    case 503: return "Служба временно недоступна. Попробуйте ещё раз."
    default: return "Не удалось выполнить запрос."
    }
  }

  func close() {
    closed = true
    onChange = nil
    onSelection = nil
    request?.cancel()
    api.close()
  }

  deinit {
    request?.cancel()
    if !closed { api.close() }
  }
}
