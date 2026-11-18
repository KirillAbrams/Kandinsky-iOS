// Показывает боковой список чатов на айфоне. Недавние чаты читает из сохранённого списка, а архив
// и поиск подгружает порциями. Через эту панель пользователь меняет чаты и управляет входом.

import UIKit

private final class StudioHistoryBrand: UIView {
  // Рисует знак Кандинского в верхней части панели тем же способом, что и в остальных окнах. Так
  // оформление не зависит от повторного открытия истории.
  override func draw(_ rect: CGRect) {
    KandinskyPalette.studioBrand(x: bounds.minX, top: 0, placement: .drawer)
  }
}

@MainActor
final class StudioHistoryController: UIViewController, UITableViewDataSource, UITableViewDelegate,
  UITextFieldDelegate
{
  private let network: NetworkSync
  private let selected: ChatID?
  private let onOpen: (ChatID) -> Void
  private let onCompose: () -> Void
  private let onLogout: () -> Void
  private let onEraseAccount: () -> Void
  private let onDeleted: (ChatID) -> Void
  var onClose: (() -> Void)?

  private let scrim = UIControl()
  private let panel = UIView()
  private let brand = StudioHistoryBrand()
  private let close = UIButton(type: .system)
  private let search = UITextField()
  private let archive = UIButton(type: .system)
  private let create = UIButton(type: .system)
  private let table = UITableView(frame: .zero, style: .plain)
  private let email = UILabel()
  private let avatar = UILabel()
  private let accountMenu = UIButton(type: .system)
  private let logout = UIButton(type: .system)
  private let divider = UIView()
  private let footer = UIButton(type: .system)
  private var rows: [StudioThread] = []
  private var localRecentIDs: Set<ChatID> = []
  private struct Section {
    let title: String?
    let threads: [StudioThread]
  }
  private var sections: [Section] = []
  private let pageSize = 30
  private var offset = 0
  private var archived = false
  private var hasMore = true
  private var loading = false
  private var readingRecent = false
  private var leaving = false
  private var failed = false
  private var mutating = false
  private var loadTask: Task<Void, Never>?
  private var loadID = 0

  // Запоминает действующую службу, текущий чат и команды перехода. Сама панель показывает список
  // поверх чата и передаёт смену экрана его владельцу.
  init(
    network: NetworkSync, selected: ChatID?, onOpen: @escaping (ChatID) -> Void,
    onCompose: @escaping () -> Void, onLogout: @escaping () -> Void,
    onEraseAccount: @escaping () -> Void, onDeleted: @escaping (ChatID) -> Void
  ) {
    self.network = network
    self.selected = selected
    self.onOpen = onOpen
    self.onCompose = onCompose
    self.onLogout = onLogout
    self.onEraseAccount = onEraseAccount
    self.onDeleted = onDeleted
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
  }

  // Останавливает создание из сохранённой разметки. Без действующей службы и команд перехода
  // панель не сможет открывать и менять чаты.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  // Создаёт поиск, архив, таблицу и команды аккаунта, затем подписывает панель на изменения
  // списка. Недавние чаты обновляются из местной копии после события, пока панель открыта.
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.accessibilityIdentifier = "chats.list"
    scrim.backgroundColor = UIColor.black.withAlphaComponent(0.54)
    scrim.accessibilityLabel = "Закрыть историю"
    scrim.accessibilityIdentifier = "chats.drawer.close"
    scrim.isAccessibilityElement = true
    scrim.accessibilityTraits = .button
    scrim.addAction(UIAction { [weak self] _ in self?.leave() }, for: .touchUpInside)
    view.addSubview(scrim)
    panel.layer.cornerRadius = 16
    panel.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    panel.clipsToBounds = true
    panel.backgroundColor = .white
    panel.accessibilityIdentifier = "chats.drawer"
    view.addSubview(panel)
    brand.backgroundColor = .clear
    brand.isAccessibilityElement = true
    brand.accessibilityLabel = "Kandinsky Studio"
    close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.tintColor = KandinskyPalette.studioInk
    close.accessibilityIdentifier = "chats.header.close"
    close.accessibilityLabel = "Закрыть историю"
    close.addAction(UIAction { [weak self] _ in self?.leave() }, for: .touchUpInside)

    var filled = UIButton.Configuration.filled()
    filled.title = "Новый чат"
    filled.image = UIImage(named: "KandinskyDrawerAdd")?
      .preparingThumbnail(of: CGSize(width: 18, height: 18))?.withRenderingMode(.alwaysTemplate)
    filled.imagePadding = 8
    filled.baseBackgroundColor = KandinskyPalette.studioInk
    filled.cornerStyle = .fixed
    filled.background.cornerRadius = 11
    filled.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
      var result = values
      result.font = .systemFont(ofSize: 15, weight: .medium)
      return result
    }
    filled.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18)
    create.configuration = filled
    create.accessibilityIdentifier = "chats.compose"
    create.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.leave(then: self.onCompose)
      }, for: .touchUpInside)

    search.placeholder = "Поиск по чатам"
    search.accessibilityIdentifier = "chats.search.field"
    search.accessibilityLabel = "Поиск по чатам"
    search.backgroundColor = KandinskyPalette.studioSurface
    search.layer.cornerRadius = 10
    search.font = .systemFont(ofSize: 15)
    search.textColor = KandinskyPalette.studioInk
    search.attributedPlaceholder = NSAttributedString(
      string: "Поиск по чатам",
      attributes: [
        .foregroundColor: KandinskyPalette.studioMuted, .font: UIFont.systemFont(ofSize: 15),
      ])
    search.clearButtonMode = .whileEditing
    search.returnKeyType = .search
    search.autocorrectionType = .no
    search.delegate = self
    let searchIcon = UIImageView(
      image: UIImage(named: "KandinskyDrawerSearch")?
        .preparingThumbnail(of: CGSize(width: 18, height: 18))?.withRenderingMode(.alwaysTemplate))
    searchIcon.tintColor = KandinskyPalette.studioInk
    searchIcon.contentMode = .center
    searchIcon.frame = CGRect(x: 16, y: 11, width: 18, height: 18)
    let searchAccessory = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 40))
    searchAccessory.addSubview(searchIcon)
    search.leftView = searchAccessory
    search.leftViewMode = .always
    search.addAction(
      UIAction { [weak self] _ in self?.reload(debounce: true) }, for: .editingChanged)

    archive.accessibilityIdentifier = "chats.archive"
    archive.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.archived.toggle()
        self.updateArchive()
        self.reload()
      }, for: .touchUpInside)
    updateArchive()

    table.dataSource = self
    table.delegate = self
    table.register(StudioThreadCell.self, forCellReuseIdentifier: "thread")
    table.separatorStyle = .none
    table.rowHeight = 44
    table.keyboardDismissMode = .onDrag
    table.contentInsetAdjustmentBehavior = .never
    table.sectionHeaderTopPadding = 0
    table.accessibilityIdentifier = "chats.rows"

    email.text = "Аккаунт"
    email.accessibilityValue = network.profile.name
    email.font = .systemFont(ofSize: 15)
    email.textColor = KandinskyPalette.studioInk
    email.lineBreakMode = .byTruncatingTail
    avatar.text = "К"
    avatar.textAlignment = .center
    avatar.font = .systemFont(ofSize: 15, weight: .medium)
    avatar.textColor = KandinskyPalette.studioInk
    avatar.backgroundColor = UIColor(
      red: 177.0 / 255, green: 237.0 / 255, blue: 215.0 / 255, alpha: 1)
    avatar.layer.cornerRadius = 16
    avatar.clipsToBounds = true
    accountMenu.setImage(
      UIImage(named: "KandinskyDrawerMore")?.withRenderingMode(.alwaysTemplate), for: .normal)
    accountMenu.tintColor = KandinskyPalette.studioMuted
    accountMenu.accessibilityLabel = "Управление аккаунтом"
    accountMenu.accessibilityIdentifier = "chats.manageAccount"
    accountMenu.menu = UIMenu(children: [
      UIAction(title: "Удалить аккаунт", attributes: .destructive) { [weak self] _ in
        guard let self else { return }
        self.leave(then: self.onEraseAccount)
      }
    ])
    accountMenu.showsMenuAsPrimaryAction = true
    divider.backgroundColor = KandinskyPalette.studioBorder
    configureTile(logout, title: "Выйти", icon: "KandinskyDrawerLogout")
    logout.accessibilityIdentifier = "chats.account"
    logout.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.leave(then: self.onLogout)
      }, for: .touchUpInside)

    footer.setTitleColor(KandinskyPalette.studioMuted, for: .normal)
    footer.titleLabel?.font = .systemFont(ofSize: 15)
    footer.contentHorizontalAlignment = .leading
    var footerStyle = UIButton.Configuration.plain()
    footerStyle.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 24, bottom: 0, trailing: 16)
    footerStyle.baseForegroundColor = KandinskyPalette.studioMuted
    footer.configuration = footerStyle
    footer.accessibilityIdentifier = "chats.empty"
    footer.addAction(UIAction { [weak self] _ in self?.loadPage() }, for: .touchUpInside)
    for item in [
      brand, close, create, search, archive, table, divider, avatar, email, logout, accountMenu,
    ] {
      panel.addSubview(item)
    }
    network.onStudioRecentChanged = { [weak self] in
      guard let self, !self.leaving else { return }
      guard self.showingRecent else {
        self.reload()
        return
      }
      guard self.offset <= StudioRecentPage.catalogLimit,
        !self.loading || self.readingRecent
      else { return }
      self.loadRecent()
    }
    reload()
  }

  // Расставляет кнопки и список между верхней полосой и нижним краем над клавиатурой.
  // Пересчитывает нижнюю строку, чтобы она подходила новой ширине таблицы.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrim.frame = view.bounds
    let width = min(304, view.bounds.width)
    panel.bounds = CGRect(x: 0, y: 0, width: width, height: view.bounds.height)
    panel.center = CGPoint(x: width / 2, y: view.bounds.midY)
    let top = view.safeAreaInsets.top
    let keyboard = max(0, view.bounds.height - view.keyboardLayoutGuide.layoutFrame.minY)
    let bottom = view.bounds.height - max(view.safeAreaInsets.bottom, keyboard)
    brand.frame = CGRect(x: 16, y: top + 20, width: width - 80, height: 24)
    close.frame = CGRect(x: width - 56, y: top + 10, width: 44, height: 44)
    create.frame = CGRect(x: 16, y: top + 72, width: width - 32, height: 44)
    search.frame = CGRect(x: 16, y: top + 128, width: width - 32, height: 40)
    archive.frame = CGRect(x: 0, y: top + 180, width: width, height: 44)
    logout.frame = CGRect(x: 0, y: bottom - 44, width: width, height: 44)
    email.frame = CGRect(x: 60, y: logout.frame.minY - 52, width: width - 124, height: 52)
    avatar.frame = CGRect(x: 16, y: logout.frame.minY - 42, width: 32, height: 32)
    accountMenu.frame = CGRect(x: width - 56, y: logout.frame.minY - 48, width: 44, height: 44)
    divider.frame = CGRect(x: 16, y: email.frame.minY, width: width - 32, height: 1)
    table.frame = CGRect(
      x: 0, y: top + 232, width: width,
      height: max(0, divider.frame.minY - top - 232))
    updateFooter()
  }

  // Сначала раскладывает окно, затем начинает движение от края на ширину готовой панели. Так
  // панель появляется из нужного места даже при другой ширине экрана.
  func enter() {
    view.layoutIfNeeded()
    panel.transform = CGAffineTransform(translationX: -panel.bounds.width, y: 0)
    scrim.alpha = 0
    UIView.animate(withDuration: 0.246, delay: 0, options: [.curveEaseOut, .beginFromCurrentState])
    {
      self.panel.transform = .identity
      self.scrim.alpha = 1
    }
  }

  // Прячет клавиатуру, прекращает загрузку и отключает действия до закрытия. Команда открытия или
  // выхода выполняется только после снятия панели.
  private func leave(then action: (() -> Void)? = nil) {
    view.endEditing(true)
    guard presentingViewController != nil, !leaving else { return }
    leaving = true
    view.isUserInteractionEnabled = false
    loadTask?.cancel()
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
      self.panel.transform = CGAffineTransform(translationX: -self.panel.bounds.width, y: 0)
      self.scrim.alpha = 0
    } completion: { _ in
      self.dismiss(animated: false) {
        self.onClose?()
        action?()
      }
    }
  }

  // Обрабатывает жест закрытия для служб доступности тем же путём, что и кнопка. Панель корректно
  // вернёт управление прежнему экрану.
  override func accessibilityPerformEscape() -> Bool {
    leave()
    return true
  }

  // Считает длину после предполагаемой замены и разрешает не более ста символов. Вставка длинной
  // строки не обходит ограничение поиска.
  func textField(
    _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
    replacementString string: String
  ) -> Bool {
    ((textField.text ?? "") as NSString).replacingCharacters(in: range, with: string).count <= 100
  }

  // Снимает фокус по кнопке клавиатуры. Уже введённый текст остаётся в поиске, а список получает
  // больше места.
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  // Задаёт широкой кнопке подпись, значок и отступы. Архив и выход получают одинаковый порядок
  // элементов и область нажатия.
  private func configureTile(_ button: UIButton, title: String, icon: String) {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.image = UIImage(named: icon)?
      .preparingThumbnail(of: CGSize(width: 18, height: 18))?.withRenderingMode(.alwaysTemplate)
    config.imagePadding = 12
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { values in
      var result = values
      result.font = .systemFont(ofSize: 15)
      return result
    }
    config.baseForegroundColor = KandinskyPalette.studioInk
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    button.configuration = config
    button.contentHorizontalAlignment = .leading
  }

  // Меняет подпись и значок в зависимости от того, открыт архив или общий список. Кнопка
  // сообщает, куда приведёт следующее нажатие.
  private func updateArchive() {
    configureTile(
      archive, title: archived ? "Все чаты" : "Архив",
      icon: archived ? "KandinskyDrawerBack" : "KandinskyDrawerArchive")
  }

  // Убирает крайние пробелы, чтобы пустой ввод возвращал недавние чаты.
  private var query: String { (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
  // Местный список используется, только когда закрыт архив и поиск пуст.
  private var showingRecent: Bool { !archived && query.isEmpty }

  // Отменяет прежнее чтение, сбрасывает границу и выбирает местный список или первый сетевой
  // запрос. Запоздалый результат другого поиска не подменит новый.
  private func reload(debounce: Bool = false) {
    loadTask?.cancel()
    loadID += 1
    rows = []
    localRecentIDs = []
    offset = 0
    hasMore = true
    failed = false
    loading = false
    readingRecent = false
    if showingRecent {
      loadRecent()
      rebuildSections()
      return
    }
    rebuildSections()
    loadPage(debounce: debounce)
  }

  // Читает сохранённые карточки и проверяет номер запроса перед показом. Отмечает их как уже
  // доступные на телефоне и меняет таблицу лишь при другом составе или состоянии.
  private func loadRecent() {
    loadTask?.cancel()
    loadID += 1
    let ticket = loadID
    readingRecent = true
    loading = true
    failed = false
    updateFooter()
    loadTask = Task { [weak self, network] in
      let page = try? await network.cachedStudioRecent()
      guard let self, self.loadID == ticket, !Task.isCancelled else { return }
      self.readingRecent = false
      self.loading = false
      guard let page else {
        self.failed = true
        self.updateFooter()
        return
      }
      self.offset = page.nextOffset ?? 0
      self.hasMore = page.nextOffset != nil
      self.localRecentIDs = Set(page.threads.map(\.id))
      if self.rows != page.threads {
        self.rows = page.threads
        self.rebuildSections()
      } else {
        self.updateFooter()
      }
    }
  }

  // Загружает следующую порцию поиска, архива или продолжения списка. Убирает повторные чаты и
  // применяет ответ только к тому запросу, который ещё отображается.
  private func loadPage(debounce: Bool = false) {
    guard !loading, hasMore || failed else { return }
    if showingRecent && offset == 0 {
      loadRecent()
      return
    }
    loading = true
    failed = false
    updateFooter()
    let ticket = loadID
    let query = self.query
    let view = archived ? "archive" : query.isEmpty ? "recent" : "all"
    let offset = self.offset
    loadTask = Task { [weak self, network, pageSize] in
      do {
        if debounce { try await Task.sleep(for: .milliseconds(240)) }
        let next = try await network.studioThreads(
          view: view, query: query, offset: offset, limit: pageSize)
        guard let self, self.loadID == ticket, !Task.isCancelled else { return }
        let known = Set(self.rows.map(\.id))
        self.rows += next.filter { !known.contains($0.id) }
        self.offset += next.count
        self.hasMore = next.count == pageSize
        self.loading = false
        self.rebuildSections()
      } catch {
        guard let self, self.loadID == ticket, !Task.isCancelled else { return }
        self.loading = false
        self.failed = true
        self.updateFooter()
      }
    }
  }

  // Собирает архив, календарные группы или простой список поиска из текущих строк. Затем
  // обновляет таблицу и нижнюю подсказку в одном порядке.
  private func rebuildSections() {
    if archived {
      sections = [Section(title: "Архив", threads: rows)]
    } else if query.isEmpty {
      sections = StudioHistorySections.make(rows).map {
        Section(title: $0.title, threads: $0.threads)
      }
    } else {
      sections = [Section(title: nil, threads: rows)]
    }
    table.reloadData()
    updateFooter()
  }

  // Показывает ожидание, повтор, продолжение или причину пустого списка. Действие на нижней
  // строке включается только тогда, когда можно начать следующий запрос.
  private func updateFooter() {
    let title: String
    if readingRecent {
      title = ""
    } else if loading {
      title = "Загрузка…"
    } else if failed {
      title = "Повторить загрузку"
    } else if hasMore {
      title = "Показать ещё"
    } else if rows.isEmpty {
      title = !query.isEmpty ? "Чаты не найдены" : archived ? "Архив пуст" : "Чатов пока нет"
    } else {
      title = ""
    }
    footer.setTitle(title, for: .normal)
    footer.isUserInteractionEnabled = !loading && (failed || hasMore)
    let height: CGFloat = title.isEmpty ? 0 : 48
    if table.tableFooterView == nil || footer.frame.width != table.bounds.width
      || footer.frame.height != height
    {
      footer.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: height)
      table.tableFooterView = footer
    }
  }

  // Возвращает текущее число групп для таблицы. Система не будет запрашивать строки групп,
  // которых теперь нет.
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }
  // Возвращает число чатов в заданной группе. При переходе в архив или поиске таблица получает
  // размер именно нового списка.
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].threads.count
  }
  // Оставляет место под заголовок только у группы с названием. Результаты поиска без заголовка не
  // получают пустую полосу.
  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    sections[section].title == nil ? 0 : 36
  }
  // Создаёт видимый заголовок с короткой подписью группы. Для списка без подписи возвращает
  // отсутствие заголовка.
  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard let title = sections[section].title else { return nil }
    let frame = UIView()
    frame.backgroundColor = .white
    let label = UILabel(
      frame: CGRect(x: 16, y: 8, width: max(1, tableView.bounds.width - 32), height: 22))
    label.text = title
    label.font = .systemFont(ofSize: 12)
    label.textColor = KandinskyPalette.studioMuted
    frame.addSubview(label)
    return frame
  }

  // Привязывает повторно используемую строку к текущему чату и заменяет прежнее действие
  // открытия. Иначе нажатие могло бы открыть чат из предыдущего прокрученного ряда.
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell =
      tableView.dequeueReusableCell(withIdentifier: "thread", for: indexPath) as! StudioThreadCell
    let row = sections[indexPath.section].threads[indexPath.row]
    cell.bind(row, selected: selected == row.id, menu: menu(row))
    cell.openButton.removeAction(identifiedBy: .init("open"), for: .touchUpInside)
    cell.openButton.addAction(
      UIAction(identifier: .init("open")) { [weak self] _ in self?.open(row) }, for: .touchUpInside)
    return cell
  }

  // Для уже открытого чата просто закрывает панель. Сохранённый недавний чат открывает сразу, а
  // найденную на сервере карточку сначала принимает в местное хранилище.
  private func open(_ row: StudioThread) {
    guard !mutating, !leaving else { return }
    if selected == row.id {
      leave()
      return
    }
    if localRecentIDs.contains(row.id) {
      leave { self.onOpen(row.id) }
      return
    }
    mutating = true
    Task {
      defer { mutating = false }
      do {
        try await network.admitStudioThread(row)
        leave { self.onOpen(row.id) }
      } catch { showError() }
    }
  }

  // Собирает доступные команды для текущего чата. Закрепление предлагается только вне архива, а
  // подпись действий показывает текущее направление изменения.
  private func menu(_ row: StudioThread) -> UIMenu {
    var actions = [UIAction(title: "Переименовать") { [weak self] _ in self?.rename(row) }]
    if !row.archived {
      actions.append(
        UIAction(title: row.pinned ? "Открепить" : "Закрепить") { [weak self] _ in
          self?.change(row, StudioThreadChange(pinned: !row.pinned))
        })
    }
    actions.append(
      UIAction(title: row.archived ? "Вернуть из архива" : "В архив") { [weak self] _ in
        self?.change(row, StudioThreadChange(archived: !row.archived))
      })
    actions.append(
      UIAction(title: "Удалить", attributes: .destructive) { [weak self] _ in
        self?.confirmDelete(row)
      })
    return UIMenu(children: actions)
  }

  // Подставляет нынешнее название и принимает непустой текст в пределах ста символов. Пустое или
  // случайно длинное название не уйдёт в запрос.
  private func rename(_ row: StudioThread) {
    let alert = UIAlertController(title: "Переименовать чат", message: nil, preferredStyle: .alert)
    alert.addTextField {
      $0.text = row.title
      $0.accessibilityIdentifier = "chats.rename.input"
    }
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
        guard
          let title = alert?.textFields?.first?.text?.trimmingCharacters(
            in: .whitespacesAndNewlines), !title.isEmpty
        else { return }
        self?.change(row, StudioThreadChange(title: String(title.prefix(100))))
      })
    present(alert, animated: true)
  }

  // Посылает изменение выбранного чата и обновляет список после подтверждения. Пока запрос идёт,
  // второе изменение не начнётся.
  private func change(_ row: StudioThread, _ value: StudioThreadChange) {
    guard !mutating else { return }
    mutating = true
    Task {
      defer { mutating = false }
      do {
        try await network.changeStudioThread(row.id, change: value)
        reload()
      } catch { showError() }
    }
  }

  // Показывает пользователю, какие данные удалятся, и ждёт отдельного подтверждения. Одно
  // случайное нажатие в списке не удалит историю.
  private func confirmDelete(_ row: StudioThread) {
    let alert = UIAlertController(
      title: "Удалить чат?", message: "Запросы и результаты этого чата будут удалены.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.delete(row) })
    present(alert, animated: true)
  }

  // Передаёт удаление по номеру и ждёт ответа. Для выбранного чата закрывает панель и сообщает
  // владельцу экрана, для другого обновляет список.
  private func delete(_ row: StudioThread) {
    guard !mutating else { return }
    mutating = true
    Task {
      defer { mutating = false }
      do {
        try await network.deleteStudioThread(row.id)
        if selected == row.id { leave { self.onDeleted(row.id) } } else { reload() }
      } catch { showError() }
    }
  }

  // Показывает подсказку о неудачном действии, пока панель ещё видима. Закрытому экрану окно
  // ошибки больше не нужно.
  private func showError() {
    let alert = UIAlertController(
      title: "Не удалось выполнить действие", message: "Проверьте соединение и повторите.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Понятно", style: .default))
    if view.window != nil { present(alert, animated: true) }
  }

  // Отменяет незавершённое чтение при освобождении панели. Больше нет экрана, которому можно
  // передать результат.
  deinit { loadTask?.cancel() }
}
