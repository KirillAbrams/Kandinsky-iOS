// Полноэкранная галерея на айфоне держит открытую страницу и по одной соседней. Она согласует
// свайпы с подгрузкой истории, переносит поверхность проигрывателя между страницами и оставляет
// сохранённый кадр до готовности видео. Оригинал фото получает только выбранная страница, чтобы
// соседние не делили с ней память.

import UIKit

@MainActor final class MediaGalleryController: UIViewController, UIScrollViewDelegate {
  @MainActor private final class Page {
    var entry: MediaGalleryEntry
    var slot = 1
    let photo: PhotoViewerController
    // Связываем страницу с записью истории и её просмотрщиком. При смене места в окне передвигаем
    // и используем ту же страницу, пока файл остаётся прежним.
    init(_ entry: MediaGalleryEntry, _ photo: PhotoViewerController) {
      self.entry = entry
      self.photo = photo
    }
  }
  var onReturn: (() -> Void)?
  var onDeleteResult: ((MessageID, String) -> Void)?
  // По действию удаления различаем итог генерации и обычное вложение с возвратом в ленту.
  private var studioPlayback: Bool { onDeleteResult != nil }
  private var model: MediaGalleryWindow
  private let repository: ChatRepository, media: MediaStore, playback: MediaCoordinator,
    surface: InlinePlayerSurface
  private let owner = UUID(), previousOwner: UUID?
  private let pager = UIScrollView(), caption = UITextView(), titleLabel = UILabel(),
    closeButton = UIButton(type: .system), retry = UIButton(type: .system)
  private let moreButton = UIButton(type: .system)
  private let topShade = CAGradientLayer(), bottomShade = CAGradientLayer()
  private var galleryPreloads: [String: MediaCancellation] = [:]
  private var pages: [String: Page] = [:], cancelled = Set<String>()
  private var seedPreview: PreparedImage?, seedID: String?
  private var task: Task<Void, Never>?, pendingPage: HistoryPage?, lastRequestID: String?
  private var observer: UUID?, activeVideo: MediaGalleryEntry?, parkedVideo: MediaGalleryEntry?
  private var lastSelectionID: String?
  private var playingDuringSwipe = false, preparingLocalVideo = false
  private var appeared = false, closing = false, cleaned = false, recentring = false,
    startingVideo = false, controlsHidden = false
  private var returnToChat = true
  // Пока страница под пальцем или ещё движется к центру, откладываем перестановку соседей.
  private var pageIsMoving: Bool {
    pager.isDragging || pager.isDecelerating
      || pager.bounds.width > 0 && abs(pager.contentOffset.x - pager.bounds.width) > 1
  }
  private let date: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMMM, HH:mm"
    return f
  }()

  // Открываем окно на выбранном вложении сообщения и запоминаем переданный из ленты кадр.
  // Сохраняем владельца проигрывателя, чтобы после закрытия вернуть обычное видео в чат.
  init(
    seed: Message, repository: ChatRepository, media: MediaStore, playback: MediaCoordinator,
    surface: InlinePlayerSurface, preview: PreparedImage?, attachmentIndex: Int = 0
  ) {
    model = MediaGalleryWindow(seed: seed, attachmentIndex: attachmentIndex)
    self.repository = repository
    self.media = media
    self.playback = playback
    self.surface = surface
    seedPreview = preview
    seedID = model.selected?.id
    previousOwner = playback.presentationOwner
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
    modalTransitionStyle = .crossDissolve
  }
  // Галерее нужны история, хранилище и общее воспроизведение при создании. Файл разметки не
  // передаёт эти связи.
  required init?(coder: NSCoder) { fatalError() }
  // Оставляем системные подписи светлыми поверх тёмного фона просмотра.
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  // Создаём полноэкранную область свайпа, дату, подпись и кнопки. Подписываемся на проигрыватель
  // до первой раскладки, чтобы получить готовый кадр и изменения состояния.
  override func loadView() {
    view = UIView()
    view.backgroundColor = .black
    view.isOpaque = true
    view.clipsToBounds = true
    view.accessibilityIdentifier = "media.viewer"
    pager.delegate = self
    pager.isPagingEnabled = true
    pager.showsHorizontalScrollIndicator = false
    pager.showsVerticalScrollIndicator = false
    pager.delaysContentTouches = false
    pager.contentInsetAdjustmentBehavior = .never
    pager.accessibilityIdentifier = "viewer.pages"
    view.addSubview(pager)
    topShade.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.clear.cgColor]
    bottomShade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.78).cgColor]
    view.layer.addSublayer(topShade)
    view.layer.addSublayer(bottomShade)
    titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
    titleLabel.textColor = .white
    titleLabel.accessibilityIdentifier = "viewer.item"
    caption.font = .systemFont(ofSize: 16)
    caption.textColor = .white
    caption.backgroundColor = .clear
    caption.isEditable = false
    caption.isSelectable = true
    caption.textContainerInset = .zero
    caption.textContainer.lineFragmentPadding = 0
    caption.accessibilityIdentifier = "viewer.caption"
    caption.showsVerticalScrollIndicator = false
    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = .white
    closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    closeButton.layer.cornerRadius = 22
    closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    retry.setImage(UIImage(systemName: "arrow.down"), for: .normal)
    retry.tintColor = .white
    retry.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    retry.layer.cornerRadius = 24
    retry.accessibilityIdentifier = "media.retry"
    retry.accessibilityLabel = "Повторить загрузку"
    retry.isHidden = true
    retry.addAction(UIAction { [weak self] _ in self?.retryVideo() }, for: .touchUpInside)
    moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    moreButton.tintColor = .white
    moreButton.accessibilityIdentifier = "viewer.result.actions"
    moreButton.accessibilityLabel = "Действия с результатом"
    moreButton.addAction(
      UIAction { [weak self] _ in self?.confirmResultRemoval() }, for: .touchUpInside)
    for control in [titleLabel, caption, closeButton, moreButton, retry] {
      view.addSubview(control)
    }
    observer = playback.observeChanges { [weak self] in self?.playerChanged() }

    reconcile()
    loadNeighbours()
  }
  // После появления разрешаем выбранной странице загрузку и воспроизведение. Для результата
  // генерации также слушаем возвращение сцены, чтобы поднять остановленный показ.
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if !appeared, studioPlayback, let scene = view.window?.windowScene {
      NotificationCenter.default.addObserver(
        self, selector: #selector(resumeAutoplay), name: UIScene.didActivateNotification,
        object: scene)
    }
    appeared = true
    activate()
  }
  // Заново активируем текущий ролик генерации после возврата приложения, если проигрыватель уже
  // отпустил его. Когда прежний ролик ещё закреплён, второй запуск не нужен.
  @objc private func resumeAutoplay() {
    guard studioPlayback, !closing, activeVideo != nil, playback.currentMessageID == nil else {
      return
    }
    activeVideo = nil
    activate()
  }
  // Расставляем страницы и кнопки с учётом системных отступов. При смене ширины сохраняем долю
  // пройденного свайпа, иначе промежуточная страница прыгнула бы в центр.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let old = pager.bounds.width, fraction = old > 0 ? pager.contentOffset.x / old - 1 : 0
    recentring = true
    pager.frame = CGRect(x: -10, y: 0, width: view.bounds.width + 20, height: view.bounds.height)
    pager.contentSize = CGSize(width: pager.bounds.width * 3, height: pager.bounds.height)
    layoutPages()
    pager.contentOffset = CGPoint(x: (1 + fraction) * pager.bounds.width, y: 0)
    recentring = false
    closeButton.frame = CGRect(
      x: view.bounds.width - 56, y: view.safeAreaInsets.top + 4, width: 44, height: 44)
    moreButton.frame = CGRect(
      x: view.bounds.width - 104, y: view.safeAreaInsets.top + 4, width: 44, height: 44)
    titleLabel.frame = CGRect(
      x: 16, y: view.safeAreaInsets.top + 10,
      width: max(1, view.bounds.width - (moreButton.isHidden ? 84 : 118)), height: 32)
    let video = model.selected?.isVideo == true,
      bottom = view.safeAreaInsets.bottom + (video ? 68 : 24)
    let h =
      caption.text.isEmpty
      ? 0
      : min(
        180,
        caption.sizeThatFits(
          CGSize(width: max(1, view.bounds.width - 32), height: .greatestFiniteMagnitude)
        ).height)
    caption.frame = CGRect(
      x: 16, y: view.bounds.height - bottom - h, width: view.bounds.width - 32, height: h)
    retry.frame = CGRect(x: view.bounds.midX - 24, y: view.bounds.midY - 24, width: 48, height: 48)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topShade.frame = CGRect(
      x: 0, y: 0, width: view.bounds.width, height: view.safeAreaInsets.top + 70)
    bottomShade.frame = CGRect(
      x: 0, y: caption.frame.minY - 24, width: view.bounds.width, height: h + 32)
    CATransaction.commit()

  }
  // Размещаем каждую удерживаемую страницу в её боковом или центральном месте. Если поверхность
  // видео уже прикреплена к ней, подгоняем размер вместе со страницей.
  private func layoutPages() {
    for page in pages.values {
      page.photo.view.frame = CGRect(
        x: CGFloat(page.slot) * pager.bounds.width + 10, y: 0, width: view.bounds.width,
        height: view.bounds.height)
      if surface.superview === page.photo.view { surface.frame = page.photo.view.bounds }
    }
  }
  // Обновляем окно вокруг выбранного вложения. Повторно используем страницы того же файла,
  // закрываем удалённые и сохраняем ручную отмену загрузки при уходе. Только после расстановки
  // возвращаем страницу в центр и согласуем проигрыватель.
  private func reconcile() {
    guard !closing else { return }
    guard let selected = model.selected else {
      close()
      return
    }
    let wanted = model.neighbours, ids = Set(wanted.map(\.id))
    for (id, page) in Array(pages)
    where !ids.contains(id)
      || wanted.first(where: { $0.id == id }).map({ !$0.hasSameMedia(as: page.entry) }) == true
    {
      if page.photo.downloadPausedByUser {
        cancelled.insert(id)
      } else {
        cancelled.remove(id)
      }
      if surface.superview === page.photo.view { retireVideo() }
      page.photo.willMove(toParent: nil)
      page.photo.closePage()
      page.photo.view.removeFromSuperview()
      page.photo.removeFromParent()
      pages.removeValue(forKey: id)
    }
    for entry in wanted {
      if let page = pages[entry.id] {
        page.entry = entry
        continue
      }
      let initial = entry.id == seedID ? seedPreview : nil
      if initial != nil { seedPreview = nil }
      let photo = PhotoViewerController(
        attachment: entry.attachment, media: media, preview: initial, embedded: true,
        playbackKey: entry.isVideo
          ? VideoPlaybackKey(messageID: entry.messageID, attachment: entry.attachment) : nil)
      let page = Page(entry, photo)
      pages[entry.id] = page
      addChild(photo)
      photo.loadViewIfNeeded()
      photo.view.accessibilityIdentifier = "viewer.page." + entry.id
      pager.addSubview(photo.view)
      photo.didMove(toParent: self)
      photo.onRequestDismiss = { [weak self] in self?.close() }
      photo.onToggleControls = { [weak self] in self?.toggleControls() }
      photo.onZoomChanged = { [weak self] zoomed in
        guard let self, self.model.selected?.id == entry.id else { return }
        self.pager.isScrollEnabled = !zoomed
      }
      photo.onPreviewReady = { [weak self] in
        guard let self, (self.activeVideo ?? self.parkedVideo)?.id == entry.id,
          entry.isVideo,
          !self.surface.hasVideoFrame
        else { return }
        self.surface.setPoster(self.pages[entry.id]?.photo.retainedPreview())
      }
      if cancelled.contains(entry.id) { photo.pauseOriginal() }
    }
    cancelled.formIntersection(Set(model.entries.map(\.id)))
    if let selectedIndex = model.selectedIndex {
      for page in pages.values {
        if let index = model.entries.firstIndex(where: { $0.id == page.entry.id }) {
          page.slot = index - selectedIndex + 1
        }
      }
    }
    recentring = true
    layoutPages()
    pager.contentOffset = CGPoint(x: pager.bounds.width, y: 0)
    recentring = false
    pager.isScrollEnabled = !(pages[selected.id]?.photo.pageIsZoomed ?? false)
    moreButton.isHidden = controlsHidden || !canDelete(selected)
    caption.text = selected.caption
    caption.isHidden = controlsHidden || selected.caption.isEmpty
    titleLabel.text =
      (selected.isVideo ? "Видео" : "Фото") + " · "
      + date.string(from: Date(timeIntervalSince1970: Double(selected.savedAtMs) / 1000))
    closeButton.accessibilityIdentifier = selected.isVideo ? "player.inline" : "photo.close"
    closeButton.accessibilityLabel = selected.isVideo ? "Вернуть в чат" : "Закрыть фотографию"
    view.setNeedsLayout()
    activate()
    prepareGalleryNeighbours()
  }
  // Готовим местные кадры на расстоянии двух позиций, чтобы следующий свайп реже показывал грубый
  // кадр. Отменяем ушедшие задачи, а сеть для такого соседства не открываем.
  private func prepareGalleryNeighbours() {
    guard let index = model.selectedIndex else { return }
    let farther = [index - 2, index + 2].filter { model.entries.indices.contains($0) }
      .map { model.entries[$0] }
    let ids = Set(farther.map(\.id))
    for id in Array(galleryPreloads.keys) where !ids.contains(id) {
      galleryPreloads.removeValue(forKey: id)?.cancel()
    }
    for entry in farther where galleryPreloads[entry.id] == nil {
      var key = media.studioPhotoKey(entry.attachment) ?? ThumbnailKey(maxPixel: 384)
      key.gallery = true
      galleryPreloads[entry.id] = media.thumbnail(
        attachment: entry.attachment, key: key, ticket: 0, localOnly: true, priority: 0
      ) { _, result in
        if case let .success(frame) = result { frame.close() }
      }
    }
  }
  // Снимаем нагрузку с прежнего оригинала до запуска нового. Для фото включаем загрузку на
  // выбранной странице. Для видео пробуем продолжить отложенное воспроизведение или перенести
  // прежнюю поверхность из чата, чтобы не терять кадр.
  private func activate() {
    guard appeared, !closing, let selected = model.selected else { return }
    // Прежний оригинал освобождает ресурсы до получения памяти следующей страницей
    for page in pages.values where page.entry.id != selected.id || selected.isVideo {
      page.photo.setPageActive(false)
    }
    let previousSelection = lastSelectionID
    lastSelectionID = selected.id
    if !selected.isVideo {
      pages[selected.id]?.photo.setPageActive(true)
      parkVideo(beside: selected, previousSelection: previousSelection)
      retry.isHidden = true
      return
    }
    guard let page = pages[selected.id] else { return }
    if activeVideo?.id == selected.id, activeVideo?.hasSameMedia(as: selected) == true { return }
    if parkedVideo?.id == selected.id, parkedVideo?.hasSameMedia(as: selected) == true,
      ownsVideo(selected), !cancelled.contains(selected.id)
    {
      parkedVideo = nil
      activeVideo = selected
      if !playingDuringSwipe { playback.resume(immediately: true) }
      playingDuringSwipe = false
      playerChanged()
      return
    }
    if parkedVideo != nil { retireVideo() }
    let reuse =
      !studioPlayback && playback.currentMessageID == selected.messageID
      && playback.currentTarget?.attachment.relativePath == selected.attachment.relativePath
    if reuse {
      surface.removeFromSuperview()
      activeVideo = nil
    } else {
      retireVideo()
    }
    activeVideo = selected
    placeSurface(on: page, keepFrame: reuse && surface.hasVideoFrame)
    if !studioPlayback, cancelled.contains(selected.id) {
      surface.isHidden = true
      retry.isHidden = false
      return
    }
    startingVideo = true
    if !reuse { startVideo(selected) }
    surface.isHidden = false
    surface.attach()
    startingVideo = false
    playerChanged()
  }

  // Сверяем владельца проигрывателя, номер сообщения, путь вложения и ошибку. Одного номера
  // сообщения мало, поскольку в нём может быть несколько файлов.
  private func ownsVideo(_ entry: MediaGalleryEntry) -> Bool {
    playback.presentationOwner == owner && playback.currentMessageID == entry.messageID
      && playback.currentTarget?.attachment.relativePath == entry.attachment.relativePath
      && playback.lastError == nil
  }

  // Ставим соседний ролик на паузу и помечаем сохранённый кадр для показа, если поверхность можно
  // удержать. Если её освободили, можем подготовить ранее просмотренного соседа из местного файла
  // с места остановки.
  private func parkVideo(beside selected: MediaGalleryEntry, previousSelection: String?) {
    if let previous = activeVideo {
      if pages[previous.id] != nil, ownsVideo(previous), surface.hasVideoFrame {
        activeVideo = nil
        parkedVideo = previous
        playback.pause()
        media.markShownInGallery(previous.attachment)
        pages[previous.id]?.photo.showLastVideoFrame()
      } else {
        retireVideo()
      }
    }
    if playingDuringSwipe {
      playingDuringSwipe = false
      playback.pause()
    }
    guard parkedVideo == nil, previousSelection != selected.id,
      let index = model.selectedIndex
    else { return }
    let oldIndex = model.entries.firstIndex(where: { $0.id == previousSelection })
    let direction = oldIndex.map { $0 > index ? -1 : 1 } ?? 1
    for neighbour in [index + direction, index - direction] where model.entries.indices.contains(neighbour) {
      let entry = model.entries[neighbour]
      guard entry.isVideo, !cancelled.contains(entry.id), let page = pages[entry.id],
        media.videoPlayback.position(VideoPlaybackKey(
          messageID: entry.messageID, attachment: entry.attachment)) > 0
      else { continue }
      parkedVideo = entry
      placeSurface(on: page, keepFrame: false)
      startVideo(entry, preparing: true)
      surface.isHidden = false
      surface.attach()
      break
    }
  }

  // Подключаем общую поверхность к нужной странице и записываем её владельца. Пока собственного
  // кадра нет, позволяет видеть подготовленное изображение страницы.
  private func placeSurface(on page: Page, keepFrame: Bool) {
    playback.presentationOwner = owner
    surface.circular = false
    // Кадр страницы виден до первого кадра проигрывателя.
    surface.showsGalleryPageBehind = true
    page.photo.view.addSubview(surface)
    surface.frame = page.photo.view.bounds
    surface.setPoster(keepFrame ? nil : page.photo.retainedPreview())
  }

  // Передаём проигрывателю конкретное вложение сообщения. Для подготовки соседа ставим его сразу
  // на паузу и читаем только местный файл, а выбранный ролик запускаем обычным путём.
  private func startVideo(_ entry: MediaGalleryEntry, preparing: Bool = false) {
    preparingLocalVideo = preparing
    playback.play(
      target: PlaybackTarget(
        attachment: entry.attachment, messageID: entry.messageID, kind: entry.kind,
        loopPreview: studioPlayback),
      startPaused: preparing, localOnly: preparing)
  }

  // Снимаем поверхность и освобождаем принадлежащее галерее воспроизведение, когда оно больше не
  // нужно. Странице оставляем сохранённый кадр, чтобы при уходе не мелькнула пустота.
  private func retireVideo(stop: Bool = true) {
    let previous = activeVideo ?? parkedVideo
    playingDuringSwipe = false
    preparingLocalVideo = false
    parkedVideo = nil
    if let previous, surface.hasVideoFrame { media.markShownInGallery(previous.attachment) }
    activeVideo = nil
    surface.detach()
    surface.removeFromSuperview()
    if previous != nil && stop, playback.presentationOwner == owner { playback.stop() }
    if let previous { pages[previous.id]?.photo.showLastVideoFrame() }
  }
  // Обновляем поверхность после ответа проигрывателя и подставляем сохранённый кадр, пока живой
  // не готов. Если выбранному ролику не хватило местного файла при подготовке, повторяем запуск
  // обычным путём. У привычного видео ошибка оставляет кнопку повтора.
  private func playerChanged() {
    guard !closing, let entry = activeVideo ?? parkedVideo else { return }
    surface.update()
    guard activeVideo != nil else {
      surface.isHidden = !ownsVideo(entry)
      return
    }
    if preparingLocalVideo, playback.lastError != nil {
      // Если свайп оказался быстрее проверки файла, открываем выбранное видео обычным способом.
      retireVideo()
      activate()
      return
    }
    let stopped = !startingVideo && playback.currentMessageID == nil
    let failed = playback.lastError != nil || cancelled.contains(entry.id) || stopped
    retry.isHidden = studioPlayback || !failed
    surface.isHidden = failed
    if !failed, !surface.hasVideoFrame {
      surface.setPoster(pages[entry.id]?.photo.retainedPreview())
    }
  }
  // Снимаем отметку отмены выбранного видео, закрываем прежнее воспроизведение и активируем его
  // снова. Без снятия отметки повтор остался бы заблокирован.
  private func retryVideo() {
    guard let entry = model.selected, entry.isVideo else { return }
    cancelled.remove(entry.id)
    retireVideo()
    activate()
  }
  // Разрешаем меню удаления только для входящего серверного результата при наличии обработчика.
  // Исходный пользовательский файл не проходит эту проверку.
  private func canDelete(_ entry: MediaGalleryEntry) -> Bool {
    onDeleteResult != nil && entry.isIncoming && entry.attachment.relativePath.hasPrefix("remote/")
  }
  // Предлагаем удалить выбранный результат и передаём номер сообщения и ключ конкретного файла
  // только после нажатия. Остальные вложения того же запроса не становятся целями операции.
  private func confirmResultRemoval() {
    guard let entry = model.selected, canDelete(entry), let remove = onDeleteResult else { return }
    let menu = UIAlertController(
      title: "Действия с результатом", message: nil, preferredStyle: .actionSheet)
    menu.addAction(
      UIAlertAction(title: "Удалить результат", style: .destructive) { _ in
        remove(entry.messageID, entry.attachment.thumbnailKey)
      })
    menu.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    menu.popoverPresentationController?.sourceView = moreButton
    menu.popoverPresentationController?.sourceRect = moreButton.bounds
    present(menu, animated: true)
  }
  // Одним касанием скрываем или возвращаем подпись, кнопки и затемнение. После возврата кнопка
  // удаления всё равно зависит от текущего вложения.
  private func toggleControls() {
    controlsHidden.toggle()
    moreButton.isHidden = controlsHidden || !(model.selected.map(canDelete) ?? false)
    titleLabel.isHidden = controlsHidden
    closeButton.isHidden = controlsHidden
    caption.isHidden = controlsHidden || caption.text.isEmpty
    topShade.isHidden = controlsHidden
    bottomShade.isHidden = controlsHidden || caption.text.isEmpty
  }
  // Просим хранилище вернуть ограниченную порцию фото и видео вокруг выбора. Во время жеста
  // откладываем применение ответа до остановки, иначе страница могла бы сместиться под пальцем.
  private func loadNeighbours() {
    guard !closing, task == nil, model.needsPage, let entry = model.selected,
      lastRequestID != entry.id
    else { return }
    lastRequestID = entry.id
    let request = PageRequest(
      chatID: entry.chatID, anchor: entry.order, direction: .around, limit: 32, visualOnly: true)
    task = Task { [weak self, repository] in
      do {
        let page = try await repository.history(request)
        guard let self, !self.closing, !Task.isCancelled else { return }
        self.task = nil
        if self.pageIsMoving {
          self.pendingPage = page
        } else {
          _ = self.model.merge(page)
          self.reconcile()
        }
      } catch {
        guard let self, !self.closing else { return }
        self.task = nil
        self.lastRequestID = nil
      }
    }
  }
  // Оставляем смещение в пределах доступных соседей. При живом движении передаём долю свайпа
  // проигрывателю, не принимая за жест программное центрирование.
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard !recentring, let index = model.selectedIndex, pager.bounds.width > 0 else { return }
    let lower = index > 0 ? 0 : pager.bounds.width,
      upper = index + 1 < model.entries.count ? pager.bounds.width * 2 : pager.bounds.width
    let x = min(max(pager.contentOffset.x, lower), upper)
    if x != pager.contentOffset.x {
      recentring = true
      pager.contentOffset.x = x
      recentring = false
    }
    if pager.isDragging || pager.isDecelerating {
      updateVideoDuringSwipe(x / pager.bounds.width - 1)
    }
  }
  // Возобновляем подготовленный ролик, когда видна большая часть его страницы. Ставим обратно на
  // паузу при отступлении ниже отдельной границы, чтобы положение у порога не дёргало пуск.
  private func updateVideoDuringSwipe(_ offset: CGFloat) {
    guard let entry = parkedVideo, let slot = pages[entry.id]?.slot, slot != 1,
      ownsVideo(entry), playback.isReady
    else { return }
    let visibleFraction = offset * CGFloat(slot - 1)
    if !playingDuringSwipe, visibleFraction >= 0.6 {
      playingDuringSwipe = true
      playback.resume(immediately: true)
    } else if playingDuringSwipe, visibleFraction < 0.5 {
      playingDuringSwipe = false
      playback.pause()
    }
  }
  // Закрепляем страницу сразу после отпускания пальца, если движение по инерции не начнётся. При
  // инерции решение откладывает следующий системный вызов.
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settle() }
  }
  // Если новый жест перехватил незаконченный переход, принимаем ближайшую страницу и переводим её
  // в центр без видимого сдвига. Полученную историю объединяем уже с этим выбором.
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard !closing, !recentring, pager.bounds.width > 0 else { return }
    let offset = pager.contentOffset.x, slot = Int((offset / pager.bounds.width).rounded())
    guard let target = pages.values.first(where: { $0.slot == slot }),
      target.entry.id != model.selected?.id
    else { return }
    let shift = CGFloat(slot - 1) * pager.bounds.width
    guard model.select(target.entry.id) else { return }
    if let page = pendingPage {
      pendingPage = nil
      _ = model.merge(page)
    }
    reconcile()
    recentring = true
    pager.contentOffset.x = offset - shift
    recentring = false
    loadNeighbours()
  }
  // Фиксируем выбранную страницу после инерции. Только теперь разрешаем применить порцию соседей
  // и пересобрать окно.
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
  // После программного пролистывания применяем то же завершение, что и после жеста. Тогда модель
  // и показанная страница совпадают.
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }
  // Выбираем страницу по конечному смещению, добавляем отложенных соседей и расставляем окно
  // вокруг нового центра. Затем проверяем, нужно ли ещё читать историю.
  private func settle() {
    guard !closing, !recentring, pager.bounds.width > 0 else { return }
    let slot = Int((pager.contentOffset.x / pager.bounds.width).rounded())
    if let target = pages.values.first(where: { $0.slot == slot }) {
      _ = model.select(target.entry.id)
    }
    if let page = pendingPage {
      pendingPage = nil
      _ = model.merge(page)
    }
    reconcile()
    loadNeighbours()
  }
  // Отменяем устаревший запрос соседей при обновлении текущего чата и применяем изменения к
  // модели. Удаление последнего файла закрывает просмотр. При движении перестройка ждёт конца
  // жеста.
  func apply(_ delta: MessageDelta) {
    guard !closing, delta.chat.id == model.chatID else { return }
    task?.cancel()
    task = nil
    pendingPage = nil
    lastRequestID = nil
    model.apply(delta)
    if model.selected == nil {
      close()
      return
    }
    if !pageIsMoving {
      reconcile()
      loadNeighbours()
    }
  }
  // Отмечаем закрытие до отмены запросов, чтобы поздние ответы не вернули страницы. Если экран
  // больше не отдаётся в чат, сразу останавливаем видео. Остальные ресурсы снимает общая уборка.
  func close(animated: Bool = true, returnToChat: Bool = true) {
    guard !closing else { return }
    closing = true
    task?.cancel()
    task = nil
    pendingPage = nil
    self.returnToChat = returnToChat
    if !returnToChat { retireVideo() }
    if presentingViewController != nil {
      dismiss(animated: animated) { [weak self] in self?.finishClose() }
    } else {
      finishClose()
    }
  }
  // Запускаем уборку, если окно было закрыто извне или исчезло без штатной кнопки. Отмеченный
  // процесс закрытия выполняет её своим продолжением.
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if !closing {
      closing = true
      finishClose()
    }
  }
  // Один раз снимаем подписки и закрываем страницы. При обычном возврате можем оставить ленте
  // владельца и позицию видео, а также сохранить готовые кадры на время перехода. При уходе из
  // чата освобождаем лишние изображения.
  private func finishClose() {
    guard !cleaned else { return }
    cleaned = true
    galleryPreloads.values.forEach { $0.cancel() }
    galleryPreloads.removeAll()
    NotificationCenter.default.removeObserver(
      self, name: UIScene.didActivateNotification, object: nil)
    task?.cancel()
    task = nil
    if let observer { playback.removeChangeObserver(observer) }
    observer = nil
    let returning =
      returnToChat && !studioPlayback && model.selected?.isVideo == true
      && playback.currentMessageID == model.selected?.messageID
      && playback.presentationOwner == owner
    if !returning {
      retireVideo()
    } else {
      playback.rememberPlayback()
      surface.removeFromSuperview()
      activeVideo = nil
    }
    surface.showsGalleryPageBehind = false
    surface.isHidden = false
    if playback.presentationOwner == owner { playback.presentationOwner = previousOwner }
    for page in pages.values {
      page.photo.closePage()
      page.photo.willMove(toParent: nil)
      page.photo.view.removeFromSuperview()
      page.photo.removeFromParent()
    }
    pages.removeAll()
    seedPreview?.close()
    seedPreview = nil
    let callback = onReturn
    onReturn = nil
    if returnToChat {
      // При выходе из просмотра последний кадр снова нужен в ленте.
      media.withNavigationCache { callback?() }
    } else {
      media.releaseIdleImages()
      callback?()
    }
  }
}
