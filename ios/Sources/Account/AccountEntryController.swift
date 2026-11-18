// Рисует форму входа на айфоне, выбирает видимые поля и передаёт введённые значения модели. По
// шагам формы можно пройти при открытой клавиатуре.

import UIKit

@MainActor private final class AccountEntryBackdrop: UIView {
  // Рисует белую подложку на всю область формы. Без заполнения сквозь окно могли бы проступить
  // прежние слои.
  override func draw(_ rect: CGRect) {
    UIColor.white.setFill()
    UIRectFill(bounds)
  }
}
@MainActor private final class AccountEntryBrand: UIView {
  // Рисует знак Кандинского в отведённой области, используя те же настройки, что и экран чата.
  // Размер и размещение остаются одинаковыми при повторном показе формы.
  override func draw(_ rect: CGRect) {
    KandinskyPalette.studioBrand(x: 85, top: 8, placement: .welcome)
  }
}

@MainActor final class AccountEntryController: UIViewController {
  var selected: ((NetworkProfile) -> Void)?
  var cancelled: (() -> Void)?
  private let model: AccountEntryViewModel
  private var displayedStep = AccountEntryStep.login

  // Создаёт модель формы из службы запросов и подготавливает окно, которое строится из кода.
  // Форма не создаёт подключение самостоятельно.
  init(api: NetworkAPI) {
    model = AccountEntryViewModel(api: api)
    super.init(nibName: nil, bundle: nil)
  }

  // Закрывает способ загрузки этой формы из сохранённой разметки. Для инициализации ей нужна явно
  // переданная служба входа.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Storyboard не используется") }
  private let codeField = UITextField()
  private let forgot = UIButton(type: .system), resend = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let stack = UIStackView(), passwordField = UITextField(), emailField = UITextField(),
    error = UILabel()
  private let submit = UIButton(type: .system), toggle = UIButton(type: .system)
  private let passwordVisibility = UIButton(type: .system)
  // Собирает прокручиваемую форму, поля, подсказки и кнопки сохранённых входов. Привязывает их к
  // модели и держит форму над клавиатурой, чтобы кнопки оставались доступны.
  override func viewDidLoad() {
    super.viewDidLoad()
    let background = AccountEntryBackdrop()
    background.backgroundColor = .white
    background.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(background)
    NSLayoutConstraint.activate([
      background.topAnchor.constraint(equalTo: view.topAnchor),
      background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      background.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])
    let scroll = UIScrollView()
    scroll.keyboardDismissMode = .interactive
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    let content = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(content)
    let glass = UIView()
    glass.translatesAutoresizingMaskIntoConstraints = false
    glass.layer.cornerRadius = 24
    glass.clipsToBounds = true
    content.addSubview(glass)
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    glass.addSubview(stack)
    let preferred = glass.widthAnchor.constraint(equalToConstant: 430)
    preferred.priority = .defaultHigh
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
      glass.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      glass.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      glass.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 24),
      glass.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
      glass.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
      glass.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
      preferred, stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -24)
    ])
    let brand = AccountEntryBrand()
    brand.isOpaque = false
    brand.accessibilityIdentifier = "account.brand"
    brand.accessibilityLabel = "Кандинский"
    brand.isAccessibilityElement = true
    brand.heightAnchor.constraint(equalToConstant: 48).isActive = true
    stack.addArrangedSubview(brand)
    stack.setCustomSpacing(28, after: brand)
    let title = titleLabel
    title.text = "Войти в студию"
    title.font = .systemFont(ofSize: 31, weight: .semibold)
    title.numberOfLines = 0
    title.textColor = .black
    stack.addArrangedSubview(title)
    let caption = UILabel()
    caption.text = "Изображения и видео\nв одном чате"
    caption.font = .systemFont(ofSize: 15)
    caption.numberOfLines = 0
    caption.textColor = .darkGray
    stack.addArrangedSubview(caption)
    for (field, id, placeholder) in [
      (emailField, "account.username", "Электронная почта"),
      (codeField, "account.code", "Код из письма"),
      (passwordField, "account.name", "Пароль")
    ] {
      field.borderStyle = .none
      field.backgroundColor = KandinskyPalette.studioSurface
      field.textColor = .black
      field.font = .systemFont(ofSize: 16)
      field.layer.cornerRadius = 12
      field.accessibilityIdentifier = id
      field.placeholder = placeholder
      field.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
      let inset = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
      field.leftView = inset
      field.leftViewMode = .always
      stack.addArrangedSubview(field)
    }
    codeField.textContentType = .oneTimeCode
    codeField.keyboardType = .numberPad
    passwordField.isSecureTextEntry = true
    passwordField.textContentType = .password
    passwordField.autocorrectionType = .no
    passwordField.spellCheckingType = .no
    passwordField.autocapitalizationType = .none
    passwordField.returnKeyType = .go
    passwordField.addAction(UIAction { [weak self] _ in self?.enter() }, for: .editingDidEndOnExit)
    passwordVisibility.frame = CGRect(x: 0, y: 0, width: 46, height: 46)
    passwordVisibility.tintColor = KandinskyPalette.studioInk
    passwordVisibility.accessibilityIdentifier = "account.passwordVisibility"
    passwordVisibility.addAction(
      UIAction { [weak self] _ in self?.togglePasswordVisibility() }, for: .touchUpInside)
    passwordField.rightView = passwordVisibility
    passwordField.rightViewMode = .always
    updatePasswordVisibility()
    emailField.textContentType = .emailAddress
    emailField.autocapitalizationType = .none
    emailField.autocorrectionType = .no
    emailField.spellCheckingType = .no
    emailField.keyboardType = .emailAddress
    emailField.returnKeyType = .next
    emailField.addAction(
      UIAction { [weak self] _ in self?.passwordField.becomeFirstResponder() },
      for: .editingDidEndOnExit)
    error.numberOfLines = 0
    error.textColor = .systemRed
    error.accessibilityIdentifier = "account.error"
    stack.addArrangedSubview(error)
    submit.accessibilityIdentifier = "account.submit"
    submit.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = KandinskyPalette.studioInk
    configuration.cornerStyle = .large
    submit.configuration = configuration
    submit.addAction(UIAction { [weak self] _ in self?.enter() }, for: .touchUpInside)
    stack.addArrangedSubview(submit)
    toggle.accessibilityIdentifier = "account.toggle"
    toggle.setTitleColor(KandinskyPalette.studioInk, for: .normal)
    toggle.addAction(
      UIAction { [weak self] _ in
        self?.model.toggleRegistration()
      }, for: .touchUpInside)
    stack.addArrangedSubview(toggle)
    forgot.setTitle("Забыли пароль?", for: .normal)
    forgot.accessibilityIdentifier = "account.forgot"
    forgot.addAction(UIAction { [weak self] _ in self?.model.startRecovery() }, for: .touchUpInside)
    stack.addArrangedSubview(forgot)
    resend.setTitle("Отправить код ещё раз", for: .normal)
    resend.accessibilityIdentifier = "account.resend"
    resend.addAction(UIAction { [weak self] _ in self?.enter(resending: true) }, for: .touchUpInside)
    stack.addArrangedSubview(resend)
    model.onChange = { [weak self] in self?.update() }
    model.onSelection = { [weak self] profile in self?.selected?(profile) }
    for profile in model.savedProfiles() {
      let button = UIButton(type: .system)
      button.setTitle(
        "Продолжить · " + (profile.username.map { "@" + $0 } ?? profile.name), for: .normal)
      button.accessibilityIdentifier = "account.saved.\(profile.userId)"
      button.contentHorizontalAlignment = .leading
      button.addAction(UIAction { [weak self] _ in self?.model.choose(profile) }, for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    if cancelled != nil {
      let button = UIButton(type: .system)
      button.setTitle("Назад к чатам", for: .normal)
      button.accessibilityIdentifier = "account.cancel"
      button.addAction(UIAction { [weak self] _ in self?.cancelled?() }, for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    update()
  }
  // Обновляет подписи и видимость полей после смены шага, очищает старые пароль и код и запрещает
  // нажатия во время запроса. Так код предыдущего шага не уйдёт в другой запрос.
  private func update() {
    let step = model.step
    let busy = model.isBusy
    if displayedStep != step {
      codeField.text = ""
      passwordField.text = ""
      displayedStep = step
    }
    if busy { view.endEditing(true) }
    error.text = model.message
    codeField.isHidden = !step.needsCode
    passwordField.isHidden = !step.needsPassword
    emailField.isEnabled = !busy && !step.needsCode
    [passwordField, codeField, submit, toggle, forgot, resend].forEach { $0.isEnabled = !busy }
    passwordField.textContentType = step == .login ? .password : .newPassword
    passwordField.placeholder = step == .verifyRecovery ? "Новый пароль" : "Пароль"
    forgot.isHidden = step != .login
    resend.isHidden = !step.needsCode
    toggle.setTitle(step == .login ? "Создать аккаунт" : "Назад ко входу", for: .normal)
    switch step {
    case .login: titleLabel.text = "Войти в студию"; submit.setTitle("Войти", for: .normal)
    case .registration, .recovery:
      titleLabel.text = step == .registration ? "Создать аккаунт" : "Восстановление пароля"
      submit.setTitle("Получить код", for: .normal)
    case .verifyRegistration, .verifyRecovery:
      titleLabel.text = step == .verifyRegistration ? "Подтверждение почты" : "Новый пароль"
      submit.setTitle(step == .verifyRegistration ? "Зарегистрироваться" : "Сохранить пароль", for: .normal)
    }
  }
  // Сверяет картинку кнопки и подпись для озвучивания с режимом поля. Пользователь слышит именно
  // то действие, которое выполнит кнопка.
  private func updatePasswordVisibility() {
    let hidden = passwordField.isSecureTextEntry
    passwordVisibility.setImage(UIImage(systemName: hidden ? "eye" : "eye.slash"), for: .normal)
    passwordVisibility.accessibilityLabel = hidden ? "Показать пароль" : "Скрыть пароль"
  }
  // Меняет скрытие пароля и возвращает текст с прежним выделением. Иначе переключение вывода
  // могло бы потерять введённое или сдвинуть курсор.
  private func togglePasswordVisibility() {
    let password = passwordField.text
    let selection = passwordField.selectedTextRange
    passwordField.isSecureTextEntry.toggle()
    passwordField.text = password
    passwordField.selectedTextRange = selection
    updatePasswordVisibility()
  }
  // Считывает текущее содержимое полей и передаёт модели вместе с признаком повторного письма.
  // Проверка остаётся общей для кнопки и клавиатуры.
  private func enter(resending: Bool = false) {
    model.submit(email: emailField.text ?? "", password: passwordField.text ?? "",
                 code: codeField.text ?? "", resending: resending)
  }

  // Просит модель остановить работу и отсоединяет действия выбора и отмены. После ухода со
  // страницы прежнее окно не получит ответ.
  func close() {
    model.close()
    selected = nil
    cancelled = nil
  }
}
