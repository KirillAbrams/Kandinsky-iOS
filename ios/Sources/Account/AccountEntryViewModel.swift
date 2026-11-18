// Управляет шагами входа, регистрации и восстановления на айфоне. Проверяет ввод, вызывает нужную
// службу и выбирает аккаунт после сохранения входа.

import Foundation

enum AccountEntryStep {
  case login, registration, recovery, verifyRegistration, verifyRecovery

  // Отдельное поле кода нужно на обоих шагах подтверждения.
  var needsCode: Bool { self == .verifyRegistration || self == .verifyRecovery }
  // Пароль нужен при входе и подтверждении, поэтому получение письма обходится без него.
  var needsPassword: Bool { self == .login || needsCode }
}

protocol AccountEntryService: AnyObject {
  // Запрашивает письмо с кодом для регистрации или восстановления. Цель передаётся явно, иначе
  // код мог бы оказаться непригодным для следующего шага.
  func requestEmailCode(email: String, recovery: Bool) async throws
  // Передаёт адрес, код подтверждения и новый пароль для восстановления. Ошибка оставляет форму
  // на текущем шаге.
  func resetPassword(email: String, code: String, password: String) async throws
  // Возвращает профиль после проверки пароля и при регистрации принимает код из письма. Такой
  // профиль можно сохранить только после ответа службы.
  func signIn(email: String, password: String, registrationCode: String?) async throws -> NetworkProfile
  // Закрывает подключение формы. После ухода со страницы она больше не должна расходовать ресурсы
  // на свой обмен.
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
  // Обозначает, что форма ждёт ответ и пока не должна начинать новое действие.
  var isBusy: Bool { request != nil }
  var onChange: (() -> Void)?
  var onSelection: ((NetworkProfile) -> Void)?

  // Принимает службу и способы чтения и сохранения профилей. В приложении используются защищённые
  // записи, а проверка может подставить свои данные.
  init(api: AccountEntryService,
       loadProfiles: @escaping () throws -> [NetworkProfile] = NetworkCredentials.profiles,
       saveProfile: @escaping (NetworkProfile) throws -> Void = NetworkCredentials.save) {
    self.api = api
    self.loadProfiles = loadProfiles
    self.saveProfile = saveProfile
  }

  // Читает сохранённые входы для быстрого выбора. При ошибке сообщает о ней и возвращает пустой
  // список, сохраняя сами записи.
  func savedProfiles() -> [NetworkProfile] {
    do { return try loadProfiles() } catch {
      message = "Не удалось прочитать сохранённые аккаунты. Данные остаются на устройстве."
      return []
    }
  }

  // Если форма свободна, сохраняет выбранный профиль и сообщает об открытии. При сбое записи
  // текущая страница остаётся на месте.
  func choose(_ profile: NetworkProfile) {
    guard !closed, !isBusy else { return }
    do {
      try saveProfile(profile)
      onSelection?(profile)
    } catch { show("Не удалось сохранить вход на устройстве.") }
  }

  // Переключает обычный вход и начало регистрации, пока нет запроса. Из других шагов возвращает
  // на вход, чтобы не продолжить неуместное подтверждение.
  func toggleRegistration() {
    guard !closed, !isBusy else { return }
    changeStep(step == .login ? .registration : .login)
  }

  // Открывает запрос кода восстановления, если форма доступна. Пока идёт другой запрос, смена
  // шага не произойдёт.
  func startRecovery() {
    guard !closed, !isBusy else { return }
    changeStep(.recovery)
  }

  // Сохраняет новый шаг и обновляет сообщение одним действием. Экран сразу получает подписи и
  // поля для этого шага.
  private func changeStep(_ next: AccountEntryStep, message: String? = nil) {
    step = next
    show(message)
  }

  // Записывает подсказку или сбрасывает её и уведомляет экран. Иначе результат запроса появится в
  // данных формы, но не станет видимым.
  private func show(_ text: String?) {
    message = text
    onChange?()
  }

  // Проверяет почту, код и пароль в зависимости от шага, затем отправляет одну подходящую
  // команду. Ответ отменённой задачи не должен заменить вход или перевести форму дальше.
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

  // Превращает известные отказы в понятные подсказки. По тексту человек может исправить код,
  // пароль или повторить запрос позже.
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

  // Помечает форму закрытой, отсоединяет уведомления, отменяет запрос и закрывает службу.
  // Запоздалый ответ не сможет открыть другой экран.
  func close() {
    closed = true
    onChange = nil
    onSelection = nil
    request?.cancel()
    api.close()
  }

  // При освобождении объекта отменяет задачу и при необходимости закрывает службу. Так
  // подключение не останется открытым, даже если явного закрытия не было.
  deinit {
    request?.cancel()
    if !closed { api.close() }
  }
}
