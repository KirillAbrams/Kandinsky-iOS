// Управляет окнами Кандинского на айфоне. Восстанавливает вход, открывает историю, передаёт
// изменения на экран и закрывает службы прежнего аккаунта.

import UIKit

@MainActor final class AppCoordinator {
  private let window: UIWindow
  private(set) var currentChatID: ChatID?
  private var runtime: AccountRuntime?
  private var store: SQLiteStore? { runtime?.store }
  private var repository: ChatRepository? { runtime?.repository }
  private var network: NetworkSync? { runtime?.network }
  private var accountEntry: AccountEntryController?
  private var pendingController: UIViewController?
  private var conversationSurface: ConversationChrome? {
    (pendingController?.view as? ConversationChrome)
      ?? (window.rootViewController?.view as? ConversationChrome)
  }
  private var media: MediaStore? { runtime?.media }
  private var playback: MediaCoordinator? { runtime?.playback }
  private let admission = MediaAdmission()
  private var state: ConversationState?
  private var studioOptions = KandinskyOptions()
  private var generation = 0
  private var allowedChatIDs: Set<ChatID> = []
  // Сохраняет окно, в котором будут показаны вход, черновик и чат. Все переходы меняют содержимое
  // одного окна.
  init(window: UIWindow) { self.window = window }

  // Заменяет набор чатов, которые можно открыть. Это не даёт старому действию показать историю с
  // недоступным номером.
  func setAllowedChats(_ ids: Set<ChatID>) { allowedChatIDs = ids }
  // Открывает папку приложения, восстанавливает вход и готовит службы аккаунта. Возвращает
  // сохранённый черновик или недавний чат, а при отсутствии входа показывает форму.
  func start(invitation: String? = nil) {
    let controller = UIViewController()
    controller.view.backgroundColor = KandinskyPalette.empty
    let label = UILabel()
    label.text = "Кандинский · открываем историю"
    label.textAlignment = .center
    label.frame = CGRect(x: 12, y: 180, width: window.bounds.width - 24, height: 60)
    label.autoresizingMask = [.flexibleWidth]
    controller.view.addSubview(label)
    window.rootViewController = controller
    Task {
      do {
        let base = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let appRoot = try AppDataRoot.resolve(base)
        let args = ProcessInfo.processInfo.arguments
        guard
          let profile = try await AccountRuntime.restoreProfile(
            root: appRoot, invitation: invitation)
        else {
          showAccountEntry()
          return
        }
        MetricsRuntime.enabled = args.contains("--metrics")
        MetricsRuntime.output = appRoot.appendingPathComponent("diagnostics/latest.json")
        let runtime = try await AccountRuntime.open(root: appRoot, profile: profile)
        self.runtime = runtime
        let sync = runtime.network
        sync.onDeltas = { [weak self] deltas in
          guard let self else { return }
          for delta in deltas {
            self.playback?.apply(delta)
            if self.currentChatID == delta.chat.id {
              if delta.chat.hidden {
                self.showChats()
              } else {
                self.conversationSurface?.apply(delta)
              }
            }
          }
          if self.currentChatID == nil {
            Task {
              if let rows = try? await self.repository?.chats(matching: "") {
                self.setAllowedChats(Set(rows.map(\.id)))
              }
            }
          }
        }
        sync.onStatus = { [weak self] text in
          self?.conversationSurface?.setNetworkStatus(text)
        }
        sync.onSessionExpired = { [weak self, weak sync] in
          guard let self, let sync, self.network === sync else { return }
          do {
            try NetworkCredentials.removeActive()
            self.switchAccount()
          } catch {
            self.conversationSurface?.setNetworkStatus("Не удалось закрыть истёкший сеанс.")
          }
        }
        sync.onAccountErased = { [weak self, weak sync] in
          if let sync { self?.eraseAccountLocally(sync) }
        }

        try await runtime.prepareMedia(admission: admission)
        guard self.runtime === runtime else { return }
        let repo = runtime.repository
        if let network {
          if let pending = try await network.savedStudioDraft(), pending.hasContent {
            showStudioDraft(network: network, restored: pending)
          } else {
            let rows = (try? await repo.chats(matching: "")) ?? []
            let saved = NetworkCredentials.selectedChat(for: network.profile.userId)
            let recent =
              rows.first { $0.id == saved && !$0.archived } ?? rows.first { !$0.archived }
            if let recent {
              allowedChatIDs.insert(recent.id)
              openChat(id: recent.id)
            } else {
              showStudioDraft(network: network, autoSelect: true)
            }
          }
        }
        network?.foreground(UIApplication.shared.applicationState != .background)

      } catch {
        let details = error as NSError
        NSLog("Kandinsky native startup failed: %@ (%ld)", details.domain, details.code)
        if let failure = error as? NetworkFailure {
          label.text = "Не удалось подключиться к Кандинскому (\(failure.status))."
        } else if let failure = error as? NetworkCredentialFailure {
          label.text = "Не удалось открыть хранилище ключей (\(failure.status))."
        } else {
          label.text = details.localizedDescription
        }
        label.numberOfLines = 3
      }
    }
  }
  // Снимает ещё не показанный экран, сохраняет его место чтения при возможности и возвращает
  // управление видимому окну. Иначе отменённый переход мог бы оставить окно недоступным.
  private func cancelPendingNavigation() {
    if let controller = pendingController {
      if let surface = controller.view as? ConversationChrome {
        if let media {
          media.withNavigationCache { surface.persistAnchorAndClose() }
        } else {
          surface.persistAnchorAndClose()
        }
      }
      controller.view.removeFromSuperview()
      pendingController = nil
    }
    window.rootViewController?.view.isUserInteractionEnabled = true
  }
  // Раскладывает новый экран в скрытом виде и временно выключает действия на старом. До
  // завершения подготовки пользователь и служба озвучивания не попадут на незагруженную историю.
  private func prepareNavigation(_ controller: UIViewController) {
    pendingController = controller
    window.rootViewController?.view.isUserInteractionEnabled = false
    let surface = controller.view!
    surface.alpha = 0
    surface.isUserInteractionEnabled = false
    surface.accessibilityElementsHidden = true
    surface.frame = window.bounds
    surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(surface)
    surface.setNeedsLayout()
    surface.layoutIfNeeded()
  }
  // Сверяет номер перехода и ожидаемый экран, затем показывает только этот экран. Запоздалое
  // завершение предыдущей загрузки не перекроет текущий чат.
  private func revealNavigation(_ controller: UIViewController, ticket: Int) {
    guard generation == ticket, pendingController === controller else { return }
    closeConversationForNavigation()
    pendingController = nil
    controller.view.removeFromSuperview()
    window.rootViewController = controller
    controller.view.alpha = 1
    controller.view.isUserInteractionEnabled = true
    controller.view.accessibilityElementsHidden = false
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
  }
  // При действующем входе открывает заготовку новой истории. Если подключения нет, закрывает
  // прежнее состояние и показывает вход, чтобы запросы не ушли без владельца.
  func showChats() {
    if let network {
      showStudioDraft(network: network)
      return
    }
    generation += 1
    cancelPendingNavigation()
    closeConversationForNavigation()
    currentChatID = nil
    let old = state
    state = nil
    Task { await old?.close() }
    showAccountEntry()
  }
  // Проверяет доступный номер, запоминает его для владельца и готовит историю с сохранённой
  // точкой. Перед показом сверяет номер перехода, чтобы медленный запрос не открыл уже покинутый
  // чат.
  func openChat(id: ChatID) {
    let openToken = MetricsRuntime.recorder.begin()
    guard allowedChatIDs.contains(id) else { return }
    saveStudioOptions()
    generation += 1
    let ticket = generation
    cancelPendingNavigation()
    (window.rootViewController?.view as? ConversationChrome)?.prepareForNavigation()
    network?.visibleChat(id)
    let old = state
    currentChatID = id
    if let network { NetworkCredentials.selectChat(id, for: network.profile.userId) }
    let controller = UIViewController()
    let model = repository.map { ConversationState(repository: $0) }
    state = model
    let surface = ConversationChrome(
      chatID: id, state: model, media: media, admission: admission, playback: playback
    ) { [weak self] in self?.openStudioDrawer() }
    surface.onNewChat = { [weak self] in self?.composeNetworkChat() }
    if network != nil { surface.restoreGenerationOptions(studioOptions) }
    surface.configureNetwork(network)
    controller.view = surface
    prepareNavigation(controller)
    guard let repository, let model else {
      revealNavigation(controller, ticket: ticket)
      return
    }
    Task {
      await old?.close()
      do {
        try await model.open(chatID: id)
        guard generation == ticket else { return }
        model.onDelta = { [weak surface] delta in surface?.apply(delta) }
        try await surface.openHistory(repository: repository, anchor: model.anchor)
        if MetricsRuntime.enabled {
          MetricsRuntime.recorder.end("chat_metadata_open_ms", openToken)
        }
      } catch { if generation == ticket { surface.showError(error) } }
      revealNavigation(controller, ticket: ticket)
    }
  }
  // Берёт настройки генерации с видимого экрана до его замены. Следующая история может начать с
  // тех же настроек.
  private func saveStudioOptions() {
    guard network != nil, let surface = window.rootViewController?.view as? ConversationChrome
    else { return }
    studioOptions = surface.generationOptions
  }
  // Восстанавливает ввод или сохраняет новую заготовку с постоянным номером. Создаёт серверный
  // чат при выборе исходника или первой отправке и сверяет актуальность перехода после ожидания.
  private func showStudioDraft(
    network: NetworkSync, autoSelect: Bool = false, restored: StudioDraftRecord? = nil
  ) {
    guard let repository else { return }
    saveStudioOptions()
    generation += 1
    let ticket = generation
    cancelPendingNavigation()
    (window.rootViewController?.view as? ConversationChrome)?.prepareForNavigation()
    network.visibleChat(nil)
    currentChatID = nil
    let old = state
    let model = ConversationState(repository: repository)
    state = model
    let controller = UIViewController()
    let surface = ConversationChrome(
      chatID: 0, state: model, media: media, admission: admission, playback: playback
    ) { [weak self] in
      self?.openStudioDrawer()
    }
    let record = restored ?? StudioDraftRecord(identity: UUID(), draft: Draft())
    let identity = record.identity
    model.persistStudioDraft = { chat, draft in
      if chat == nil {
        try await network.saveStudioDraft(draft, identity: identity)
      } else {
        try await network.finishStudioDraft(identity: identity)
      }
    }
    surface.configureNetwork(network)
    surface.restoreGenerationOptions(studioOptions)
    surface.prepareSourceDraft = { [weak self, weak model] in
      guard let self, let model, self.generation == ticket else { throw CancellationError() }
      if model.chatID == nil {
        let id = try await network.createStudioThread(id: identity)
        guard self.generation == ticket else { throw CancellationError() }
        model.bindStudioDraft(chatID: id)
        self.allowedChatIDs.insert(id)
        NetworkCredentials.selectChat(id, for: network.profile.userId)
      }
    }
    surface.onNewChat = { [weak self] in self?.composeNetworkChat() }
    surface.onFirstSend = { [weak self, weak surface, weak model] options in
      guard let self, let surface, let model, self.generation == ticket, !surface.isStartingThread
      else { return }
      surface.setStartingThread(true)
      Task {
        defer { surface.setStartingThread(false) }
        do {
          let id: Int64
          if let bound = model.chatID {
            id = bound
          } else {
            id = try await network.createStudioThread(id: identity)
          }
          guard self.generation == ticket else { return }
          model.bindStudioDraft(chatID: id)
          await model.send(generationOptions: options)
          guard self.generation == ticket else { return }
          if let error = model.lastError {
            surface.showError(error)
            return
          }
          self.allowedChatIDs.insert(id)
          self.openChat(id: id)
        } catch {
          guard self.generation == ticket else { return }
          if let failure = error as? NetworkFailure {
            NSLog("Kandinsky studio creation: HTTP %ld", failure.status)
          } else {
            let failure = error as NSError
            NSLog("Kandinsky studio creation: %@ (%ld)", failure.domain, failure.code)
          }
          self.showStudioCreationError()
        }
      }
    }
    controller.view = surface
    prepareNavigation(controller)
    Task {
      await old?.close()
      guard generation == ticket else { return }
      do {
        let previous = try await network.beginStudioDraft(record)
        if let previous, previous.identity != record.identity {
          try? await media?.discardUnpublishedImports(previous.draft.attachmentDrafts)
        }
      } catch {
        guard generation == ticket else { return }
        surface.showError(error)
        return
      }
      guard generation == ticket else { return }
      surface.openStudioDraft(record.draft)
      revealNavigation(controller, ticket: ticket)
      guard autoSelect, generation == ticket else { return }
      guard
        let rows = try? await network.studioThreads(view: "recent", query: "", offset: 0, limit: 1),
        let first = rows.first, generation == ticket, !surface.studioDraftTouched
      else { return }
      do { try await network.admitStudioThread(first) } catch { return }
      guard generation == ticket, !surface.studioDraftTouched,
        controller.presentedViewController == nil
      else { return }
      allowedChatIDs.insert(first.id)
      openChat(id: first.id)
    }
  }
  // Подключает панель к открытию, созданию и удалению чата, выходу и удалению аккаунта. При
  // удалении активной истории приложение уйдёт с её экрана.
  private func makeStudioHistoryDrawer(network: NetworkSync) -> StudioHistoryController {
    StudioHistoryController(
      network: network, selected: currentChatID,
      onOpen: { [weak self] id in
        guard let self else { return }
        self.allowedChatIDs.insert(id)
        self.openChat(id: id)
      }, onCompose: { [weak self] in self?.composeNetworkChat() },
      onLogout: { [weak self] in self?.logoutStudio() },
      onEraseAccount: { [weak self, weak network] in
        if let network { self?.confirmAccountErasure(network) }
      },
      onDeleted: { [weak self] id in
        guard let self else { return }
        self.allowedChatIDs.remove(id)
        if self.currentChatID == id { self.showChats() }
      })
  }
  // Проверяет, что поверх чата можно открыть панель, и скрывает прежний экран от озвучивания.
  // После закрытия возвращает ему отображение и доступность.
  private func openStudioDrawer() {
    guard let network else {
      showChats()
      return
    }
    guard let presenter = window.rootViewController, presenter.presentedViewController == nil,
      let surface = presenter.view as? ConversationChrome, !surface.isStartingThread
    else { return }
    let drawer = makeStudioHistoryDrawer(network: network)
    surface.setHistoryDrawerVisible(true)
    surface.accessibilityElementsHidden = true
    drawer.onClose = { [weak surface] in
      surface?.accessibilityElementsHidden = false
      surface?.setHistoryDrawerVisible(false)
    }
    presenter.present(drawer, animated: false) { drawer.enter() }
  }
  // Убирает текущий вход на телефоне и переключает экран. Запрос выхода уходит с сохранённым
  // прежним ключом, поэтому не завершит другой вход.
  private func logoutStudio() {
    guard let profile = network?.profile else { return }
    do {
      try NetworkCredentials.removeActive()
      switchAccount()
      Task {
        let api = NetworkAPI(profile: profile)
        defer { api.close() }
        _ = try? await api.json("/v1/kandinsky/logout", method: "POST")
      }
    } catch {
      let alert = UIAlertController(title: "Не удалось выйти", message: nil, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Понятно", style: .default))
      window.rootViewController?.present(alert, animated: true)
    }
  }
  // Просит пароль, разрешает подтверждение только при допустимой длине и начинает местную очистку
  // после принятия сервером. Ошибка оставляет пользователю возможность исправить пароль или
  // повторить.
  private func confirmAccountErasure(_ sync: NetworkSync) {
    guard network === sync else { return }
    let alert = UIAlertController(
      title: "Удалить аккаунт?",
      message: "История, запросы и медиа будут удалены. Для подтверждения введите пароль.",
      preferredStyle: .alert
    )
    alert.addTextField { field in
      field.placeholder = "Пароль"
      field.isSecureTextEntry = true
      field.textContentType = .password
      field.accessibilityIdentifier = "account.erasure.password"
    }
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    let confirm = UIAlertAction(title: "Удалить навсегда", style: .destructive) {
      [weak self, weak alert] _ in
      guard let self, let password = alert?.textFields?.first?.text else { return }
      Task {
        do {
          try await sync.eraseStudioAccount(password: password)
          self.eraseAccountLocally(sync)
        } catch {
          guard self.network === sync else { return }
          self.showAccountErasureError(
            (error as? NetworkFailure)?.status == 403
              ? "Неверный пароль." : "Проверьте соединение и попробуйте снова.")
        }
      }
    }
    confirm.isEnabled = false
    alert.addAction(confirm)
    if let field = alert.textFields?.first {
      field.addAction(
        UIAction { [weak field, weak confirm] _ in
          confirm?.isEnabled = (12...128).contains(field?.text?.unicodeScalars.count ?? 0)
        }, for: .editingChanged)
    }
    window.rootViewController?.present(alert, animated: true)
  }
  // Показывает причину отказа поверх текущего экрана. Человек может подтвердить сообщение и
  // попробовать ещё раз без потери текущей страницы.
  private func showAccountErasureError(_ message: String) {
    let alert = UIAlertController(
      title: "Удаление аккаунта", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Понятно", style: .default))
    window.rootViewController?.present(alert, animated: true)
  }
  // Проверяет, что уведомление относится к текущему аккаунту, и записывает отметку о его очистке.
  // После остановки приложения по ней можно продолжить удаление.
  private func eraseAccountLocally(_ sync: NetworkSync) {
    guard network === sync, let store else { return }
    let root = store.root.deletingLastPathComponent()
    let userID = sync.profile.userId
    try? NetworkCredentials.stageErasure(userID, root: root)
    switchAccount(erasing: (userID, root))
  }
  // Показывает форму с отдельным подключением для входа. После выбора сохранённого или нового
  // профиля закрывает форму и запускает открытие истории заново.
  private func showAccountEntry() {
    let entry = AccountEntryController(api: NetworkAPI(profile: nil))
    accountEntry = entry
    entry.selected = { [weak self, weak entry] _ in
      entry?.close()
      self?.accountEntry = nil
      self?.start()
    }
    window.rootViewController = entry
  }
  // Сохраняет место чтения и закрывает видимый чат. Общая память файлов помогает соседнему экрану
  // использовать уже подготовленные вложения.
  private func closeConversationForNavigation() {
    guard let surface = window.rootViewController?.view as? ConversationChrome else { return }
    if let media {
      media.withNavigationCache { surface.persistAnchorAndClose() }
    } else {
      surface.persistAnchorAndClose()
    }
  }
  // Отменяет переходы, закрывает службы и базу прежнего владельца, затем открывает вход или
  // продолжает очистку. При удалении сразу скрывает прежний экран.
  private func switchAccount(erasing: (Int64, URL)? = nil) {
    generation += 1
    cancelPendingNavigation()
    (window.rootViewController?.view as? ConversationChrome)?.persistAnchorAndClose()
    generation += 1
    let ticket = generation
    let db = store
    runtime?.closeServices()
    runtime = nil
    allowedChatIDs.removeAll()
    currentChatID = nil
    studioOptions = KandinskyOptions()
    let old = state
    state = nil
    if erasing != nil {
      let blank = UIViewController()
      blank.view.backgroundColor = KandinskyPalette.empty
      window.rootViewController = blank
    }
    Task {
      await old?.close()
      try? await db?.close()
      if let (id, root) = erasing {
        finishLocalErasure(id, root: root, ticket: ticket)
        return
      }
      guard generation == ticket else { return }
      showAccountEntry()
    }
  }
  // Вне потока экрана записывает отметку и доводит очистку до конца. При отказе оставляет повтор
  // с тем же владельцем, чтобы не пришлось начинать всё сначала.
  private func finishLocalErasure(_ id: Int64, root: URL, ticket: Int) {
    Task {
      do {
        try await Task.detached {
          try NetworkCredentials.stageErasure(id, root: root)
          try NetworkCredentials.finishErasures(root: root)
        }.value
        guard generation == ticket else { return }
        showAccountEntry()
      } catch {
        guard generation == ticket else { return }
        let alert = UIAlertController(
          title: "Не удалось очистить данные",
          message: "Повторите очистку данных этого аккаунта на устройстве.", preferredStyle: .alert)
        alert.addAction(
          UIAlertAction(title: "Повторить", style: .default) { [weak self] _ in
            self?.finishLocalErasure(id, root: root, ticket: ticket)
          })
        window.rootViewController?.present(alert, animated: true)
      }
    }
  }
  // Открывает заготовку нового чата при действующем входе. Пока первая отправка уже создаёт чат,
  // второе нажатие не начнёт новый переход.
  private func composeNetworkChat() {
    guard let network,
      (window.rootViewController?.view as? ConversationChrome)?.isStartingThread != true
    else { return }
    showStudioDraft(network: network)
  }
  // Сообщает о сбое при создании истории. Текущий экран остаётся доступен для повтора или
  // исправления исходных данных.
  private func showStudioCreationError() {
    let alert = UIAlertController(
      title: "Не удалось начать историю", message: "Проверьте соединение.", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Понятно", style: .default))
    window.rootViewController?.present(alert, animated: true)
  }

  // Передаёт сетевым службам сведения о действии пользователя. По ним служба может правильно
  // учитывать активность текущего входа.
  func userInteraction() { network?.userInteraction() }

  // При возвращении возобновляет обмен и разрешает показ вложений на видимых экранах. Если поверх
  // текущего открыто другое окно, вложения под ним не начинают работу.
  func graphicsVisible(_ value: Bool) {
    if value { network?.foreground(true) }
    (window.rootViewController?.view as? ConversationChrome)?.setMediaVisible(
      value && window.rootViewController?.presentedViewController == nil)
    (pendingController?.view as? ConversationChrome)?.setMediaVisible(value)
  }
  // При уходе в фон приостанавливает обмен и показ вложений, останавливает запись и просит
  // сохранить состояние. Это освобождает ресурсы и помогает вернуться к тому же месту.
  func background() {
    network?.foreground(false)
    MetricsRuntime.export()
    graphicsVisible(false)
    (window.rootViewController?.view as? ConversationChrome)?.stopCapture()
    stopMedia()
    flush()
  }
  // Останавливает активное воспроизведение. При потере видимости оно не продолжит использовать
  // звук и декодировать кадры.
  func stopMedia() { playback?.stop() }
  // Просит состояние сохранить накопленные изменения в отдельной задаче. Экран не стоит в
  // ожидании ответа базы, но запись получает возможность завершиться.
  func flush() { Task { try? await state?.flush() } }
  // Отменяет переходы, закрывает форму входа, службы аккаунта и окно. Очередь дочитывает нужное
  // для закрытия состояние и закрывает базу после очистки ссылок на экран.
  func close() {
    allowedChatIDs.removeAll()
    generation += 1
    cancelPendingNavigation()
    accountEntry?.close()
    accountEntry = nil
    let db = store
    runtime?.closeServices()
    runtime = nil
    admission.close()
    (window.rootViewController?.view as? ConversationChrome)?.persistAnchorAndClose()
    generation += 1
    let old = state
    state = nil
    Task {
      await old?.close()
      try? await db?.close()
    }
    currentChatID = nil
    window.rootViewController = nil
  }
}
