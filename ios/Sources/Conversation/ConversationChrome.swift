// Экран переписки на айфоне соединяет ленту, поле ввода и настройки генерации. Отправку и
// сохранение черновика выполняет состояние переписки, а сборку истории и вывод фото берёт на себя
// лента. Экран передаёт им нажатия, следит за готовностью истории и оставляет место для
// клавиатуры, вложения и полосы загрузки.

import UIKit

@MainActor final class ConversationChrome: UIView {
  private weak var network: NetworkSync?
  private var networkTitle: String?, networkStatus: String?
  // При новом состоянии связи обновляем заголовок и передаём событие загрузчику вложений. Возврат
  // сети разрешает продолжить прерванную передачу, а при явном обрыве ставим её на паузу.
  func setNetworkStatus(_ text: String) {
    guard networkStatus != text else { return }
    networkStatus = text
    headerInk.setNeedsDisplay()
    if text == "В сети" {
      attachments?.resumePendingUpload(reconnected: true)
    } else if text.hasPrefix("Нет связи") {
      attachments?.pausePendingUpload()
    }
  }
  // Подключаем обмен данными к экрану и загрузчику вложений. У сохранённого чата передаём на
  // сервер место чтения и ищем заголовок среди местных записей. У черновика без номера пока нет
  // истории, которую можно привязать к серверу.
  func configureNetwork(_ sync: NetworkSync?) {
    network = sync
    attachments?.network = sync
    sync?.onStudioTransfersChanged = { [weak self] in self?.updateStudioTransferProgress() }
    updateStudioTransferProgress()
    let id = chatID
    guard id > 0 else { return }
    onViewport = { [weak sync] anchor in sync?.viewport(chat: id, anchor: anchor) }
    Task { [weak self] in
      guard let self, let rows = try? await sync?.local.chats(matching: "") else { return }
      self.networkTitle = rows.first { $0.id == self.chatID }?.title
      self.headerInk.setNeedsDisplay()
      self.setNeedsDisplay()
    }
  }
  private var onViewport: ((ReadingAnchor) -> Void)?

  // При появлении экрана в окне даём загрузчику поднять оставшуюся передачу. Снятие экрана с окна
  // само по себе новую загрузку не начинает.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { attachments?.resumePendingUpload() }
  }

  private let onBack: () -> Void
  private let chatID: ChatID
  private let state: ConversationState?
  private let timeline = ChatScrollHost()
  private var activeGenerationID: MessageID?
  private var generationLookup: Task<Void, Never>?

  // Читаем номер активного задания и обновляем кнопку остановки. Отменяем предыдущий запрос,
  // чтобы его поздний ответ не вернул на кнопку номер уже завершённой генерации.
  private func refreshActiveGeneration() {
    guard chatID > 0, let network else { return }
    generationLookup?.cancel()
    generationLookup = Task { [weak self] in
      guard let self else { return }
      do {
        let active = try await network.activeGeneration(chat: self.chatID)
        guard !Task.isCancelled, self.activeGenerationID != active else { return }
        self.activeGenerationID = active
        self.updateSendButton()
      } catch {
        // При ошибке местного чтения сохраняем последнюю известную цель остановки
      }
    }
  }

  // Собираем вид и доступность кнопки из готовности истории, черновика и активного задания.
  // Остановку разрешаем во время задания, а обычную отправку блокируем при занятом поле или ещё
  // не готовом вложении. Подпись для озвучивания различает запуск, повтор и остановку.
  private func updateSendButton() {
    guard let state else { return }
    let stopping = activeGenerationID != nil
    let ready = state.isReady && historyReady && !isStartingThread
    send.icon = stopping ? .stop : .send
    send.isEnabled =
      ready
      && (stopping
        || (!state.isSending && attachments?.isImporting != true
          && (network != nil || canSubmitDraft)))
    send.alpha = historyReady ? 1 : 0.55
    send.accessibilityLabel =
      stopping
      ? "Остановить генерацию"
      : state.draft.operationID == nil ? "Начать генерацию" : "Повторить сохранение"
  }
  private var rowCount = 0
  private var historyReady = false
  private var studioFeedback: (panel: UIView, label: UILabel)?
  private var hadStudioPhoto = false
  private let referenceChip = StudioReferenceChip(frame: .zero)
  private let studioTransferBar = StudioTransferBar()
  private var attachments: ChatAttachmentCoordinator?
  private var transferVisible = false
  private var localTransferProgress: Double?
  var prepareSourceDraft: (() async throws -> Void)?

  // Показываем передачу с этого телефона, если она есть. Иначе считаем общий процент по сумме
  // принятых и ожидаемых байтов с других устройств, чтобы маленький и большой файлы не получили
  // одинаковый вес.
  private func updateStudioTransferProgress() {
    let remote = network?.studioTransfers.filter { $0.deviceId != network?.profile.deviceId } ?? []
    let remoteProgress =
      remote.isEmpty
      ? nil
      : Double(remote.reduce(Int64(0)) { $0 + $1.received })
        / Double(remote.reduce(Int64(0)) { $0 + $1.total })
    let progress = localTransferProgress ?? remoteProgress
    transferVisible = progress != nil
    studioTransferBar.title =
      localTransferProgress == nil ? "Загрузка на другом устройстве" : "Загрузка файла"
    studioTransferBar.progress = progress ?? 0
    setNeedsLayout()
  }
  private var actionsUI: ConversationUIController?
  private let headerGlass = UIView(frame: .zero), composerGlass = UIView(frame: .zero)
  private let composerBackdrop = UIView(frame: .zero)
  private let newChat = KandinskyIconButton(icon: .compose, id: "chat.compose", label: "Новый чат")
  private let generationSettings = KandinskyIconButton(
    icon: .tune, id: "composer.settings", label: "Параметры генерации")
  var onNewChat: (() -> Void)?
  var onFirstSend: ((KandinskyOptions) -> Void)?
  private(set) var isStartingThread = false
  // Поле в фокусе, правка текста или первый запрос означают, что человек уже занялся черновиком.
  var studioDraftTouched: Bool {
    input.isFirstResponder || (state?.draft.revision ?? 0) > 0 || isStartingThread
  }
  // Переносим только настройки, пригодные для другого запроса. Улучшение остаётся связано с текущим файлом.
  var generationOptions: KandinskyOptions {
    if options.model == "video_sr" { return KandinskyOptions() }
    var value = options
    if hadStudioPhoto { value.model = "video" }
    return value
  }

  // Возвращаем настройки из черновика и меняем подпись модели. На время восстановления выключаем
  // обратную запись, иначе изменение на экране снова запустило бы обновление черновика.
  func restoreGenerationOptions(_ value: KandinskyOptions) {
    restoringGenerationOptions = true
    defer { restoringGenerationOptions = false }
    modelName =
      value.model == "video_sr"
      ? "Улучшение видео" : value.model == "video" ? "Video Lite" : "Image Lite"
    options = value
  }
  // Разрешаем ввод до создания серверного чата и передаём сохранённый черновик в состояние. Без
  // этого новый экран ожидал бы историю, которой ещё нет.
  func openStudioDraft(_ restored: Draft? = nil) {
    historyReady = true
    state?.openStudioDraft(restored)
  }
  // Отмечаем, что идёт первый запрос на создание чата, и сразу обновляем доступность кнопок. Пока
  // сервер выдаёт номер, повторное нажатие не должно запустить второй переход.
  func setStartingThread(_ value: Bool) {
    isStartingThread = value
    state?.onChange?()
  }
  private let headerInk = NativeGlassInk(frame: .zero)
  private var headerPaintSize: CGSize?
  private var keyboardOverlap: CGFloat = 0
  private var mediaKeyboardHeight: CGFloat = 0
  private var keyboardObserver: NSObjectProtocol?
  private let back: KandinskyIconButton
  private let plus = KandinskyIconButton(
    icon: .plus, id: "composer.plus", label: "Добавить фото или видео")
  private let modelButton = KandinskyIconButton(
    icon: .chevronDown, id: "composer.model", label: "Модель генерации")
  private let modelLabel = UILabel()
  private var modelName = "Image Lite"
  private var restoringGenerationOptions = false
  private var options = KandinskyOptions() {
    // Собираем подпись модели с числом результатов. Сохраняем выбор, сделанный человеком, а при
    // восстановлении уже сохранённого значения второй записи не требуется.
    didSet {
      let count = options.count ?? 1
      modelLabel.text = count > 1 ? "\(modelName) · \(count)" : modelName
      if !restoringGenerationOptions { state?.updateGenerationOptions(options) }
    }
  }
  private var modelCatalog: [StudioModel]?
  private var loadingModels = false
  private let send = KandinskyIconButton(
    icon: .send, id: "composer.send", label: "Начать генерацию")
  private let welcome = UIButton(type: .system)
  private let input = UITextView()
  private let placeholder = UILabel()
  private var body = CGRect.zero, card = CGRect.zero, composer = CGRect.zero
  private var wallpaperBounds = CGRect.null
  // Собираем кнопки, поле ввода и ленту. Подключаем сохранение черновика, выбор исходного файла,
  // видимый ход загрузки и остановку активного задания. Перед отправкой завершаем ввод с
  // клавиатуры, чтобы в запрос попали ещё набираемые символы.
  init(
    chatID: ChatID, state: ConversationState? = nil, media: MediaStore? = nil,
    admission: MediaAdmission? = nil, playback: MediaCoordinator? = nil,
    onBack: @escaping () -> Void
  ) {
    self.onBack = onBack
    self.chatID = chatID
    self.state = state
    back = KandinskyIconButton(icon: .menu, id: "chat.back", label: "История запросов")
    super.init(frame: .zero)
    backgroundColor = .white
    accessibilityIdentifier = "chat.screen"
    headerGlass.backgroundColor = .white
    composerGlass.backgroundColor = KandinskyPalette.studioSurface
    composerGlass.layer.borderColor = KandinskyPalette.studioBorder.cgColor
    composerGlass.layer.borderWidth = 1
    headerGlass.isUserInteractionEnabled = false
    composerGlass.isUserInteractionEnabled = false
    composerBackdrop.backgroundColor = .white
    addSubview(headerGlass)
    addSubview(composerBackdrop)
    addSubview(composerGlass)
    addSubview(headerInk)
    back.circle = false
    back.iconColor = KandinskyPalette.studioInk
    back.iconSide = 24
    back.addAction(UIAction { _ in onBack() }, for: .touchUpInside)
    send.solid = true
    send.solidColor = KandinskyPalette.studioInk
    send.iconSide = 22
    send.hitExtension = 0.5
    newChat.circle = false
    newChat.iconColor = KandinskyPalette.studioInk
    newChat.iconSide = 24
    newChat.addAction(UIAction { [weak self] _ in self?.onNewChat?() }, for: .touchUpInside)
    generationSettings.circle = false
    generationSettings.iconSide = 21
    generationSettings.iconColor = KandinskyPalette.studioInk
    generationSettings.addAction(
      UIAction { [weak self] _ in self?.showGenerationSettings() }, for: .touchUpInside)
    for button in [plus, modelButton, generationSettings] {
      button.layer.borderWidth = 1
      button.layer.borderColor =
        UIColor(red: 226.0 / 255, green: 227.0 / 255, blue: 223.0 / 255, alpha: 1).cgColor
      button.layer.cornerRadius = 10
    }
    plus.iconSide = 25
    plus.hitExtension = 4
    generationSettings.layer.cornerRadius = 21
    generationSettings.layer.borderColor = KandinskyPalette.studioMuted.cgColor
    generationSettings.layer.borderWidth = 1
    for control in [plus, modelButton] {
      control.circle = false
      control.iconColor = UIColor(white: 0.12, alpha: 1)
    }
    for control in [back, plus, modelButton, send, newChat, generationSettings] {
      addSubview(control)
    }
    input.accessibilityIdentifier = "composer.input"
    input.accessibilityLabel = "Опишите изображение или видео"
    input.backgroundColor = .clear
    input.font = UIFontMetrics.default.scaledFont(
      for: PlatformTextFont.uiFont(size: 16), compatibleWith: traitCollection)
    input.adjustsFontForContentSizeCategory = true
    input.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 5, right: 10)
    input.isScrollEnabled = true
    input.layer.cornerRadius = 20
    input.textColor = .black
    input.tintColor = KandinskyPalette.blue
    addSubview(input)
    placeholder.text = "Опишите изображение или видео"
    placeholder.textColor = KandinskyPalette.studioMuted
    placeholder.font = input.font
    placeholder.isUserInteractionEnabled = false
    input.addSubview(placeholder)
    studioTransferBar.isHidden = true
    addSubview(studioTransferBar)
    referenceChip.remove.accessibilityLabel = "Удалить исходное фото"
    referenceChip.remove.accessibilityIdentifier = "studio.reference.remove"
    referenceChip.remove.addAction(
      UIAction { [weak self] _ in self?.attachments?.replacePhoto(nil) }, for: .touchUpInside)
    referenceChip.isHidden = true
    addSubview(referenceChip)
    welcome.isHidden = true
    welcome.setTitle("Попробовать с магнолией", for: .normal)
    welcome.setTitleColor(KandinskyPalette.studioInk, for: .normal)
    welcome.titleLabel?.font = .systemFont(ofSize: 13)
    welcome.accessibilityIdentifier = "chat.welcome"
    welcome.addAction(
      UIAction { [weak self] _ in
        guard let state = self?.state else { return }
        var draft = state.draft
        draft.text = "Белая магнолия у окна, мягкий дневной свет, минималистичная фотография"
        state.editDraft(draft)
      }, for: .touchUpInside)
    addSubview(welcome)
    input.delegate = self
    if state != nil {
      input.isEditable = false
      for c in [plus, modelButton, send, welcome] { c.isEnabled = false }
    }
    if let state, let media, let admission {
      attachments = ChatAttachmentCoordinator(
        view: self, state: state, media: media, admission: admission,
        presenter: { [weak self] in self?.presenter },
        options: { [weak self] in self?.options ?? KandinskyOptions() },
        selectOptions: { [weak self] in self?.restoreGenerationOptions($0) },
        showError: { [weak self] in self?.showStudioAttachmentError($0) },
        previewVideo: { [weak timeline] attachment, enhance, close in
          guard let timeline else {
            close()
            return
          }
          timeline.previewStudioVideo(attachment, onEnhance: enhance, onClose: close)
        },
        prepareDraft: { [weak self] in
          guard let self else { return }
          try await self.prepareSourceDraft?()
        },
        showProgress: { [weak self] progress in
          guard let self else { return }
          self.localTransferProgress = progress
          self.updateStudioTransferProgress()
        })
      timeline.configureMedia(media)
      if let playback {
        timeline.configurePlayback(playback, media: media)

      }
      plus.addAction(
        UIAction { [weak self] _ in
          guard let self, state.isReady, !state.isSending, state.draft.pendingSend == nil,
            state.draft.pendingMediaBatch == nil
          else { return }
          self.input.resignFirstResponder()
          self.attachments?.showPicker()
        }, for: .touchUpInside)
    }
    modelButton.iconHidden = true
    modelLabel.text = "Image Lite"
    modelLabel.font = .systemFont(ofSize: 13)
    modelLabel.textColor = KandinskyPalette.studioInk
    modelLabel.lineBreakMode = .byTruncatingTail
    modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let chevron = NativeGlassInk(frame: .zero)
    chevron.paint = { rect in
      KandinskyIconPaths.draw(.chevronDown, in: rect, color: KandinskyPalette.studioInk, width: 2.4)
    }
    let modelContent = UIStackView(arrangedSubviews: [modelLabel, chevron])
    modelContent.alignment = .center
    modelContent.spacing = 4
    modelContent.isUserInteractionEnabled = false
    modelContent.translatesAutoresizingMaskIntoConstraints = false
    modelButton.addSubview(modelContent)
    NSLayoutConstraint.activate([
      modelContent.centerXAnchor.constraint(equalTo: modelButton.centerXAnchor),
      modelContent.centerYAnchor.constraint(equalTo: modelButton.centerYAnchor),
      modelContent.leadingAnchor.constraint(
        greaterThanOrEqualTo: modelButton.leadingAnchor, constant: 8),
      chevron.widthAnchor.constraint(equalToConstant: 13),
      chevron.heightAnchor.constraint(equalToConstant: 13),
    ])
    modelButton.addAction(
      UIAction { [weak self] _ in self?.chooseGenerationOptions() }, for: .touchUpInside)
    if let state {
      insertSubview(timeline, at: 0)
      timeline.onAnchor = { [weak self, weak state] anchor in
        state?.anchor = anchor
        self?.onViewport?(anchor)
      }
      state.onChange = { [weak self, weak state] in
        guard let self, let state else { return }
        if let saved = state.draft.generationOptions, self.options != saved {
          self.restoreGenerationOptions(saved)
        }
        ComposerInputBridge.synchronize(self.input, to: state.draft.text)
        if self.network != nil {
          let source = state.draft.attachmentDrafts.first
          let hasPhoto = source?.mime.hasPrefix("image/") == true
          if source?.mime == "video/mp4" {
            if self.options.model != "video_sr" {
              self.restoreGenerationOptions(KandinskyOptions(model: "video_sr"))
            }
          } else if self.options.model == "video_sr" {
            self.restoreGenerationOptions(KandinskyOptions(model: hasPhoto ? "video" : "image"))
          } else if (hasPhoto && self.options.model != "video")
            || (!hasPhoto && self.hadStudioPhoto)
          {
            self.restoreGenerationOptions(
              KandinskyOptions(
                model: "video", aspect: self.options.aspect, count: self.options.count,
                seed: self.options.seed))
          }
          self.hadStudioPhoto = hasPhoto
        }
        self.placeholder.isHidden = !self.input.text.isEmpty
        self.attachments?.resumePendingUpload()
        self.setNeedsLayout()
        self.setNeedsDisplay()
        let ready = state.isReady && self.historyReady && !self.isStartingThread
        self.input.isEditable = ready
        self.back.isEnabled = !self.isStartingThread
        self.newChat.isEnabled = !self.isStartingThread
        for c in [self.plus, self.modelButton, self.generationSettings, self.welcome] {
          c.isEnabled = ready
          c.alpha = ready ? 1 : 0.4
        }
        self.plus.isEnabled = ready && self.attachments?.isImporting != true && !state.isSending
        self.referenceChip.remove.isEnabled = ready && !state.isSending
        self.updateSendButton()
      }
      send.addAction(
        UIAction { [weak self, weak state] _ in
          guard let self else { return }
          if let active = self.activeGenerationID {
            self.actionsUI?.performGenerationAction(active, action: .cancel)
            return
          }
          ComposerInputBridge.finish(self.input)
          guard self.canSubmitDraft else { return }
          if let onFirstSend = self.onFirstSend {
            onFirstSend(self.options)
            return
          }
          Task {
            await state?.send(generationOptions: self.options)
            if let error = state?.lastError { self.showError(error) }
          }
        }, for: .touchUpInside)
    }
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self,
          let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let local = self.convert(frame, from: nil)
        self.keyboardOverlap = max(0, self.bounds.maxY - local.minY)
        self.setNeedsLayout()
        self.layoutIfNeeded()
      }
    }
  }
  // Пустой запрос не отправляем, но оставляем путь повтора для уже сохранённой попытки.
  private var canSubmitDraft: Bool {
    guard let draft = state?.draft else { return false }
    return draft.pendingSend != nil || draft.pendingMediaBatch != nil
      || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.attachmentDrafts.isEmpty
  }

  // Показываем модели обычной генерации. После выбора оставляем исходный файл только для
  // совместимого режима, иначе старое вложение могло бы уйти в запрос с другой моделью.
  private func chooseGenerationOptions() {
    withModels { [weak self] models, presenter in
      guard let self else { return }
      let sheet = StudioGenerationSheet(options: self.options)
      sheet.showModels(models.filter { $0.id != "video_sr" }) { [weak self] model in
        guard let self else { return }
        if let source = self.state?.draft.attachmentDrafts.first,
          model.id != "video" || source.mime == "video/mp4"
        {
          self.attachments?.replacePhoto(nil)
        }
        self.modelName = model.name
        self.options = KandinskyOptions(
          model: model.id, aspect: self.options.aspect,
          count: self.options.count, seed: self.options.seed)
      }
      presenter.present(sheet, animated: true)
    }
  }

  // Ищем ближайшего владельца экрана, который может показать панель поверх переписки.
  private var presenter: UIViewController? {
    var responder: UIResponder? = self
    while let current = responder, !(current is UIViewController) { responder = current.next }
    return responder as? UIViewController
  }

  // Ищем возможности выбранной модели и отдельно учитываем исходный файл. Число результатов
  // сохраняем сразу при выборе, а остальные настройки получаем из подтверждённой формы.
  private func showGenerationSettings() {
    withModels { [weak self] models, presenter in
      guard let self, let model = models.first(where: { $0.id == self.options.model }) else {
        return
      }
      let hasReference = self.state?.draft.attachmentDrafts.isEmpty == false
      guard
        let available = (hasReference ? model.reference_capabilities : nil) ?? model.capabilities
      else { return }
      let sheet = StudioGenerationSheet(options: self.options)
      sheet.showSettings(
        available,
        onCountChange: { [weak self] count in
          self?.options.count = count
        }
      ) { [weak self] in self?.options = $0 }
      presenter.present(sheet, animated: true)
    }
  }

  // Повторно используем загруженный список и держим только один запрос за раз. После ответа
  // проверяем, что переписка ещё видна и поверх неё не открыто другое окно. Так список не
  // появится поверх чужого экрана.
  private func withModels(_ present: @escaping ([StudioModel], UIViewController) -> Void) {
    guard !loadingModels, let presenter, presenter.presentedViewController == nil else { return }
    input.resignFirstResponder()
    if let modelCatalog {
      present(modelCatalog, presenter)
      return
    }
    guard let network else { return }
    loadingModels = true
    Task { [weak self, weak presenter] in
      guard let self else { return }
      defer { self.loadingModels = false }
      let models = try? await network.studioModels()
      guard let presenter, self.window != nil, presenter.presentedViewController == nil else {
        return
      }
      guard let models, !models.isEmpty else {
        let alert = UIAlertController(
          title: "Не удалось загрузить модели", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
        presenter.present(alert, animated: true)
        return
      }
      self.modelCatalog = models
      present(models, presenter)
    }
  }

  // Убираем подписку на движения клавиатуры при уничтожении экрана. Дальнейшие системные события
  // этому экземпляру переписки уже не нужны.
  deinit { if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) } }
  // Соединяем действия над сообщениями с местным хранилищем и, при подключении, с сервером.
  // Восстанавливаем позицию, готовим первый видимый кадр и только затем разрешаем ввод. Иначе
  // экран мог бы принять запрос до готовности переписки.
  func openHistory(repository: ChatRepository, anchor: ReadingAnchor?) async throws {
    if let state {
      let ui = ConversationUIController(
        parent: self, chatID: chatID, repository: repository, state: state,
        onDelta: { [weak self] in self?.apply($0) })
      if let network {
        ui.generationAction = { [weak network, chatID] message, action, operation in
          guard let network else { throw RepoError.io }
          try await network.generationAction(
            chat: chatID, message: message, action: action, operation: operation)
        }
        ui.reportGeneration = { [weak network, chatID] message, reason in
          guard let network else { throw RepoError.io }
          try await network.reportGeneration(chat: chatID, message: message, reason: reason)
        }
        ui.deleteGenerationContent = { [weak network, chatID] message, blob in
          guard let network else { throw RepoError.io }
          try await network.deleteGenerationContent(chat: chatID, message: message, blob: blob)
        }
        timeline.onStudioResultDelete = { [weak ui] message, blob in
          ui?.removeGenerationContent(message, blob: blob)
        }
        ui.retrySlotAction = { [weak network, chatID] message, slot, operation in
          guard let network else { throw RepoError.io }
          try await network.generationAction(
            chat: chatID, message: message, action: .retry, operation: operation, slot: slot)
        }
        timeline.onStudioGenerationAction = { [weak ui] id, action in
          ui?.performGenerationAction(id, action: action)
        }
        timeline.onStudioRetrySlot = { [weak ui] id, slot in ui?.retrySlot(id, slot: slot) }
      }
      actionsUI = ui
      timeline.onMessageLongPress = { [weak ui] message, _ in ui?.menu(message: message) }
      timeline.onMessageAction = { [weak ui] message, kind in ui?.perform(kind, message: message) }
      timeline.onCountChanged = { [weak self] count in
        self?.rowCount = count
        self?.setNeedsLayout()
        self?.setNeedsDisplay()
      }
    }
    try await timeline.open(chatID: chatID, repository: repository, anchor: anchor)
    // Переход сначала добавляет экран в окно, поскольку до этого у истории нет видимой области
    if window != nil { try await timeline.prepareInitialFrame() }
    refreshActiveGeneration()
    historyReady = true
    onViewport?(timeline.readingAnchor())
    state?.onChange?()
    rowCount = timeline.messageCount
    timeline.onError = { [weak self] in self?.showError($0) }
    setNeedsLayout()
    setNeedsDisplay()
  }
  // Передаём ленте новые и изменённые строки. Когда обновление касается активного задания,
  // перечитываем его состояние для кнопки остановки. Скрытый чат закрываем обратно в список.
  func apply(_ delta: MessageDelta) {
    timeline.apply(delta)
    if delta.chat.id == chatID, network != nil {
      let rows = delta.inserted + delta.updated
      let active = activeGenerationID
      if rows.contains(where: { ($0.studioGeneration?.isActive == true) != ($0.id == active) })
        || active.map(delta.removedIDs.contains) == true
      {
        refreshActiveGeneration()
      }
    }
    if delta.chat.hidden { onBack() }
  }
  // Передаём ленте видимость вложений при смене экрана. Лента по этому признаку решает, какие
  // фото и видео сейчас стоит готовить.
  func setMediaVisible(_ visible: Bool) { timeline.setMediaVisible(visible) }
  // При открытии списка переписок закрываем клавиатуру и останавливаем движущиеся вложения под
  // ним. После закрытия списка снова разрешаем воспроизведение.
  func setHistoryDrawerVisible(_ visible: Bool) {
    if visible { input.resignFirstResponder() }
    timeline.setMovingMediaVisible(!visible)
  }
  // Просим владельца камеры закончить съёмку. Тогда после ухода со страницы камера не останется
  // занята этим окном.
  func stopCapture() { attachments?.stopCapture() }
  // Перед переходом останавливаем камеру, завершаем ввод и ставим ленту на паузу. Снимаем место
  // чтения до закрытия области, пока оно соответствует экрану.
  func prepareForNavigation() {
    stopCapture()
    input.resignFirstResponder()
    timeline.pauseForNavigation()
    state?.anchor = timeline.readingAnchor()
  }
  // Заканчиваем работу загрузчика и задачи поиска генерации, запоминаем место чтения и закрываем
  // ленту. У пустого местного чата без номера можно убрать неприкреплённый черновик.
  func persistAnchorAndClose() {
    attachments?.close(discardDraft: network == nil && chatID == 0 && state?.chatID == nil)
    generationLookup?.cancel()
    state?.anchor = timeline.readingAnchor()
    timeline.close()
  }
  // Добавляем к кнопке понятную подсказку для повтора сохранения и озвучиваем её. После ошибки
  // человек может повторить действие с той же кнопки.
  func showError(_ error: Error) {
    send.accessibilityHint = "Не удалось сохранить. Нажмите ещё раз для повтора."
    UIAccessibility.post(notification: .announcement, argument: send.accessibilityHint)
  }
  // Запрещаем создание из файла разметки. Рабочему экрану нужны номер переписки и обработчики,
  // которые передаются при создании из приложения.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }
  // При смене системного размера шрифта обновляем поле и подсказку, затем заново измеряем экран.
  // Для остальных смен оформления прежних размеров достаточно.
  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      input.font = UIFontMetrics.default.scaledFont(
        for: PlatformTextFont.uiFont(size: 16), compatibleWith: traitCollection)
      placeholder.font = input.font
      setNeedsLayout()
    }
  }
  // Раскладываем заголовок, историю и ввод между системными отступами и клавиатурой. Передаём
  // ленте запас под панели и используем те же прямоугольники для озвучиваемых кнопок. Тогда
  // последние строки и подписи остаются доступными при открытом вложении и полосе загрузки.
  override func layoutSubviews() {
    super.layoutSubviews()
    let previousCard = card
    let s = min(bounds.width / 394, 1.12)
    let top = safeAreaInsets.top
    let keyboard = max(keyboardOverlap, mediaKeyboardHeight)
    let bottom = max(safeAreaInsets.bottom, keyboard)
    let fieldHeight = max(48, ceil(input.font?.lineHeight ?? 20) + 18)
    let fieldTop: CGFloat = 8
    let fieldToButtons: CGFloat = 4
    let sendHeight: CGFloat = 49
    let buttonsBottom: CGFloat = 8.5
    let paneHeight = fieldTop + fieldHeight + fieldToButtons + sendHeight + buttonsBottom
    headerGlass.frame = CGRect(x: 0, y: 0, width: bounds.width, height: top + 57)
    headerInk.frame = CGRect(x: 0, y: top, width: bounds.width, height: 57)
    composerGlass.frame = CGRect(
      x: 14, y: bounds.height - bottom - 8 - paneHeight, width: bounds.width - 28,
      height: paneHeight)
    composerGlass.layer.cornerRadius = 18
    composer = composerGlass.frame
    let referenceVisible = network != nil && state?.draft.attachmentDrafts.isEmpty == false
    referenceChip.isHidden = !referenceVisible
    referenceChip.isVideo = state?.draft.attachmentDrafts.first?.mime == "video/mp4"
    let referenceHeight: CGFloat = referenceVisible ? 48 : 0
    referenceChip.frame = CGRect(x: composer.minX, y: composer.minY - 48, width: 107.46, height: 48)
    studioTransferBar.isHidden = !transferVisible
    studioTransferBar.frame = CGRect(
      x: composer.minX, y: composer.minY - referenceHeight - 32, width: composer.width, height: 24)
    let bodyBottom = composer.minY - referenceHeight - (transferVisible ? 40 : 8)
    body = CGRect(
      x: 0, y: headerGlass.frame.maxY, width: bounds.width,
      height: max(0, bodyBottom - headerGlass.frame.maxY))
    composerBackdrop.frame = CGRect(
      x: 0, y: bodyBottom, width: bounds.width, height: max(0, bounds.height - bodyBottom))
    timeline.frame = CGRect(
      x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - keyboard))
    timeline.updateOverlayInsets(
      top: headerGlass.frame.maxY + 6 * s, bottom: max(0, timeline.bounds.height - bodyBottom))
    let headerY = headerInk.frame.minY + 6
    back.frame = CGRect(x: 6, y: headerY, width: 44, height: 44)
    newChat.frame = CGRect(x: bounds.width - 54, y: headerY, width: 44, height: 44)
    let rowCenter = composer.maxY - buttonsBottom - sendHeight / 2
    let sendCenter = composer.maxX - 35
    let settingsCenter = sendCenter - 58
    plus.frame = CGRect(x: composer.minX + 13, y: rowCenter - 18, width: 42, height: 36)
    send.frame = CGRect(
      x: sendCenter - sendHeight / 2, y: rowCenter - sendHeight / 2, width: sendHeight,
      height: sendHeight)
    generationSettings.frame = CGRect(
      x: settingsCenter - 21, y: rowCenter - 21, width: 42, height: 42)
    let modelLeft = plus.frame.maxX + 4
    modelButton.frame = CGRect(
      x: modelLeft, y: rowCenter - 20, width: max(0, generationSettings.frame.minX - 7 - modelLeft),
      height: 40)
    send.isHidden = false
    input.frame = CGRect(
      x: composer.minX + 13, y: composer.minY + fieldTop, width: composer.width - 26,
      height: fieldHeight)
    input.layer.backgroundColor = UIColor.clear.cgColor
    input.textContainer.lineFragmentPadding = 0
    input.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 3, right: 0)
    placeholder.frame = CGRect(
      x: 0, y: 10, width: input.bounds.width, height: placeholder.font?.lineHeight ?? 22)
    card = CGRect(
      x: 32, y: max(body.minY + 12, body.midY - 105), width: max(1, bounds.width - 64), height: 210)
    welcome.isHidden = rowCount != 0 || !historyReady
    welcome.frame = CGRect(x: card.midX - 114, y: card.minY + 163, width: 228, height: 48)
    if headerPaintSize != headerInk.bounds.size {
      headerPaintSize = headerInk.bounds.size
      headerInk.paint = { rect in
        KandinskyPalette.studioBrand(x: rect.midX, top: 16)
        KandinskyPalette.studioBorder.setFill()
        UIRectFill(CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1))
      }
    }
    if let feedback = studioFeedback {
      let width = max(0, bounds.width - 48)
      let textHeight = ceil(
        feedback.label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
      let safeBottom = keyboard > safeAreaInsets.bottom ? 0 : safeAreaInsets.bottom
      let height = textHeight + 28 + safeBottom
      feedback.panel.frame = CGRect(
        x: 0, y: bounds.height - keyboard - height, width: bounds.width, height: height)
      feedback.label.frame = CGRect(x: 24, y: 14, width: width, height: textHeight)
    }
    let title = UIAccessibilityElement(accessibilityContainer: self)
    title.accessibilityIdentifier = "chat.title"
    title.accessibilityLabel = "Kandinsky"
    title.accessibilityTraits = [.staticText, .header]
    title.accessibilityFrameInContainerSpace = CGRect(
      x: bounds.midX - 80, y: headerInk.frame.midY - 16, width: 160, height: 32)
    var elements: [Any] = [back, title, newChat]
    if state != nil, chatID > 0 { elements.append(timeline) }
    if !welcome.isHidden {
      let heading = UIAccessibilityElement(accessibilityContainer: self)
      heading.accessibilityLabel = "Что создадим?"
      heading.accessibilityTraits = [.staticText, .header]
      heading.accessibilityFrameInContainerSpace = CGRect(
        x: card.minX, y: card.minY + 56, width: card.width, height: 39)
      elements += [heading, welcome]
    }
    if transferVisible { elements.append(studioTransferBar) }
    if referenceVisible { elements.append(referenceChip.remove) }
    elements += [input, plus, modelButton, generationSettings, send]
    if let feedback = studioFeedback { elements.append(feedback.label) }
    accessibilityElements = elements.map { $0 as Any }
    if wallpaperBounds != bounds || previousCard != card {
      wallpaperBounds = bounds
      setNeedsDisplay()
    }
  }
  // Рисуем белый фон и узор только в пределах истории. Для пустой переписки добавляем приглашение
  // к первой генерации, которое исчезает после появления строк.
  override func draw(_ rect: CGRect) {
    UIColor.white.setFill()
    UIRectFill(bounds)
    KandinskyWallpaper.render(bounds: body, scale: min(bounds.width / 394, 1.12))
    if rowCount == 0 {
      KandinskyPalette.studioBrand(x: card.midX, top: card.minY, placement: .welcome)
      KandinskyPalette.text(
        "Что создадим?", in: CGRect(x: card.minX, y: card.minY + 56, width: card.width, height: 39),
        size: 30, color: KandinskyPalette.studioInk, weight: .medium, alignment: .center)
      KandinskyPalette.text(
        "Опишите кадр или добавьте фото",
        in: CGRect(x: card.minX, y: card.minY + 107, width: card.width, height: 30), size: 17,
        color: KandinskyPalette.studioMuted, alignment: .center)
    }
  }

}
extension ConversationChrome: UITextViewDelegate {
  // Скрываем подсказку при вводе и передаём набранный текст в состояние черновика. На имитаторе
  // также обновляем отображение значков, прежде чем показать итоговый текст.
  func textViewDidChange(_ textView: UITextView) {
    #if targetEnvironment(simulator)
      PlatformTextFont.updateEmoji(in: textView)
    #endif
    placeholder.isHidden = !textView.text.isEmpty
    guard let state else { return }
    var draft = state.draft
    draft.text = textView.text
    state.editDraft(draft)
  }
}

extension ConversationChrome {
  // Показываем и озвучиваем временную плашку с причиной ошибки файла. При отсроченном закрытии
  // сверяем саму плашку, чтобы старый срок не убрал новое сообщение.
  private func showStudioAttachmentError(_ title: String) {
    guard window != nil else { return }
    studioFeedback?.panel.removeFromSuperview()
    let panel = UIView()
    panel.backgroundColor = UIColor(red: 44 / 255, green: 50 / 255, blue: 47 / 255, alpha: 1)
    panel.isUserInteractionEnabled = false
    let label = UILabel()
    label.numberOfLines = 0
    label.accessibilityIdentifier = "studio.attachment.error"
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 22
    paragraph.maximumLineHeight = 22
    label.attributedText = NSAttributedString(
      string: title,
      attributes: [
        .font: UIFont.systemFont(ofSize: 15),
        .foregroundColor: UIColor(red: 236 / 255, green: 242 / 255, blue: 237 / 255, alpha: 1),
        .paragraphStyle: paragraph,
      ])
    panel.addSubview(label)
    addSubview(panel)
    studioFeedback = (panel, label)
    setNeedsLayout()
    UIAccessibility.post(notification: .announcement, argument: title)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak panel] in
      guard let self, let panel, self.studioFeedback?.panel === panel else { return }
      self.studioFeedback = nil
      panel.removeFromSuperview()
      self.setNeedsLayout()
    }
  }
}

@MainActor private final class StudioTransferBar: UIView {
  var title = "Загрузка файла" {
    // Меняем озвучиваемое название полосы и запрашиваем перерисовку. Это различает передачу с
    // этого телефона и с другого устройства.
    didSet {
      accessibilityLabel = title
      setNeedsDisplay()
    }
  }
  var progress: Double = 0 {
    // Переводим долю передачи в проценты для озвучивания и перерисовываем заполнение полосы.
    // Тогда голосовая подсказка меняется вместе с видимым ходом.
    didSet {
      accessibilityValue = "\(Int(progress*100))%"
      setNeedsDisplay()
    }
  }
  // Создаём полосу загрузки как отдельный озвучиваемый элемент. Её значение часто меняется,
  // поэтому отмечаем это при настройке доступности.
  init() {
    super.init(frame: .zero)
    isOpaque = false
    isAccessibilityElement = true
    accessibilityIdentifier = "studio.upload.progress"
    accessibilityLabel = "Загрузка файла"
    accessibilityTraits = [.updatesFrequently]
  }
  // Полоса создаётся программно с настроенной подписью и озвучиванием. Создание из сохранённой
  // разметки для неё не предусмотрено.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }
  // Рисуем подпись с процентом и закрашиваем переданную долю. По незаполненной части видно, сколько
  // ещё осталось передать.
  override func draw(_ rect: CGRect) {
    let text = "\(title): \(Int(progress * 100))%"
    (text as NSString).draw(
      at: .zero,
      withAttributes: [
        .font: UIFont.systemFont(ofSize: 12), .foregroundColor: KandinskyPalette.studioInk,
      ])
    let track = CGRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4)
    UIColor(red: 206.0 / 255, green: 233.0 / 255, blue: 219.0 / 255, alpha: 1).setFill()
    UIRectFill(track)
    UIColor(red: 56.0 / 255, green: 227.0 / 255, blue: 178.0 / 255, alpha: 1).setFill()
    UIRectFill(CGRect(x: 0, y: track.minY, width: bounds.width * progress, height: track.height))
  }
}

@MainActor private final class StudioReferenceChip: UIView {
  private let photo = UIImage(named: "KandinskyAttachmentPhoto")
  private let video = UIImage(named: "KandinskyRecentVideo")
  var isVideo = false {
    // При смене вида вложения правим подпись кнопки удаления и перерисовываем ярлык. Одинаковое
    // значение оставляет готовый рисунок.
    didSet {
      guard isVideo != oldValue else { return }
      remove.accessibilityLabel = isVideo ? "Удалить исходное видео" : "Удалить исходное фото"
      setNeedsDisplay()
    }
  }
  let remove = UIButton(type: .custom)
  // Создаём ярлык исходного файла с настоящей кнопкой удаления поверх рисунка. Тогда крестик
  // можно нажать и найти через средства доступности.
  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    addSubview(remove)
  }
  // Ярлык строится программно вместе с кнопкой удаления. Загрузка из файла разметки миновала бы
  // эту настройку.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }
  // Отводим правый край ярлыка под область нажатия на крестик. Подпись слева остаётся обычной
  // частью рисунка.
  override func layoutSubviews() {
    super.layoutSubviews()
    // Согласованное оформление отдаёт правую полосу шириной тридцать шесть единиц удалению
    remove.frame = CGRect(x: 70, y: 0, width: 36, height: bounds.height)
  }
  // Передаём ярлыку касания внутри крестика. Нажатие на название вложения поэтому оставляет файл
  // в черновике.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    remove.frame.contains(point)
  }
  // Рисуем рамку, подпись и крестик, а значок берём по виду исходного файла. Пользователь видит,
  // какое вложение лежит в черновике и где его убрать.
  override func draw(_ rect: CGRect) {
    let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 5.5), cornerRadius: 8)
    UIColor.white.setFill()
    outline.fill()
    UIColor(red: 191.0 / 255, green: 201.0 / 255, blue: 195.0 / 255, alpha: 1).setStroke()
    outline.stroke()
    (isVideo ? video : photo)?.draw(in: CGRect(x: 11, y: 16, width: 16, height: 16))
    let iconColor = KandinskyPalette.studioSheetHandle
    KandinskyPalette.text(
      isVideo ? "Видео" : "Фото",
      in: CGRect(x: isVideo ? 34 : 37, y: 15, width: isVideo ? 42 : 38, height: 20), size: 14,
      color: iconColor)
    let cross = UIBezierPath()
    cross.move(to: CGPoint(x: 85, y: 19.5))
    cross.addLine(to: CGPoint(x: 94, y: 28.5))
    cross.move(to: CGPoint(x: 94, y: 19.5))
    cross.addLine(to: CGPoint(x: 85, y: 28.5))
    cross.lineWidth = 1.5
    iconColor.setStroke()
    cross.stroke()
  }
}
