// Просмотрщик на айфоне показывает одно вложение отдельно или внутри галереи. Он отдаёт выбранной
// странице крупное фото, а соседним оставляет уменьшенное изображение либо сохранённый кадр
// видео. Отмена загрузки, масштабирование и выход из просмотра проходят через этот экран.

import UIKit

@MainActor
final class PhotoViewerController: UIViewController, UIScrollViewDelegate,
  UIGestureRecognizerDelegate
{
  var onReturn: (() -> Void)?
  var onRequestDismiss: (() -> Void)?, onToggleControls: (() -> Void)?,
    onPreviewReady: (() -> Void)?, onZoomChanged: ((Bool) -> Void)?
  private let embedded: Bool, sharedStudioPhoto: Bool
  private var active: Bool, resourcesClosed = false
  private(set) var downloadPausedByUser = false
  private let attachment: Attachment, slot: MediaImageSlot, media: MediaStore
  private let playbackKey: VideoPlaybackKey?
  private let captionText: String, captionView = UITextView(), captionShade = CAGradientLayer()
  private let scroll = UIScrollView(), imageHost = UIView(), back = UIButton(type: .system)
  private let progress = MediaProgressControl(), retry = UIButton(type: .system)
  private var preview: PreparedImage?
  private var standbyPreview: PreparedImage?, originalBound = false
  private var download: Task<Void, Never>?
  private var generation = 0, hasOriginal = false, dismissing = false
  private var viewport = CGSize.zero, baseSize = CGSize.zero
  private var controlsVisible = true
  private var appeared = false

  // Принимаем файл и уже готовое изображение, если его успела показать лента. Отдельное окно
  // сразу активно, а страница внутри галереи дождётся выбора перед загрузкой оригинала.
  init(
    attachment: Attachment, media: MediaStore, preview: PreparedImage? = nil, caption: String = "",
    embedded: Bool = false, playbackKey: VideoPlaybackKey? = nil
  ) {
    self.attachment = attachment
    self.media = media
    self.preview = preview
    captionText = caption
    slot = MediaImageSlot(store: media)
    self.embedded = embedded
    self.playbackKey = playbackKey
    sharedStudioPhoto = media.studioPhotoKey(attachment) != nil
    active = !embedded
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  // Создание из файла разметки запрещено. Просмотрщику нужны конкретное вложение и доступ к
  // хранилищу при создании.
  required init?(coder: NSCoder) { fatalError() }
  // Используем светлые системные подписи, чтобы они читались на чёрном фоне.
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  // Создаём прокрутку, слой рисунка, кнопки и жесты. Ответ слоя может сохранить уменьшенный кадр
  // или сообщить галерее, что он готов. Поздний ответ для закрытой страницы сразу отбрасываем.
  override func loadView() {
    view = UIView()
    view.backgroundColor = .black
    view.isOpaque = true
    view.addSubview(scroll)
    scroll.addSubview(imageHost)
    imageHost.layer.addSublayer(slot.layer)
    scroll.delegate = self
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = embedded && attachment.mime.hasPrefix("video/") ? 1 : 4
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    slot.onReady = { [weak self] in
      guard let self, !self.resourcesClosed else { return }
      if self.embedded, self.slot.hasSharpFrame {
        self.media.markShownInGallery(self.attachment)
      }
      if self.sharedStudioPhoto {
        self.retry.isHidden = !self.active || !self.slot.loadFailed
        self.onPreviewReady?()
        return
      }
      if self.playbackKey != nil {
        self.onPreviewReady?()
        return
      }
      self.retainStandbyPreview()
      self.onPreviewReady?()
      if self.active, self.hasOriginal, !self.originalBound,
        self.standbyPreview != nil || self.slot.loadFailed
      {
        DispatchQueue.main.async { [weak self] in self?.bindImage() }
      }
      guard self.originalBound, !self.slot.loading else { return }
      self.progress.update(progress: nil, visible: false)
      self.retry.isHidden = !self.slot.loadFailed
    }
    let single = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    double.numberOfTapsRequired = 2
    single.require(toFail: double)
    scroll.addGestureRecognizer(single)
    scroll.addGestureRecognizer(double)
    let dismiss = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    dismiss.delegate = self
    view.addGestureRecognizer(dismiss)
    scroll.panGestureRecognizer.require(toFail: dismiss)
    back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    back.tintColor = .white
    back.backgroundColor = UIColor.black.withAlphaComponent(0.3)
    back.layer.cornerRadius = 22
    back.accessibilityIdentifier = "photo.close"
    back.accessibilityLabel = "Закрыть фотографию"
    back.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
    progress.addAction(
      UIAction { [weak self] _ in self?.cancelDownload(showRetry: true) }, for: .touchUpInside)
    retry.setImage(UIImage(systemName: "arrow.down.circle.fill"), for: .normal)
    retry.tintColor = .white
    retry.accessibilityIdentifier = "media.retry"
    retry.accessibilityLabel = "Загрузить оригинал"
    retry.isHidden = true
    retry.addAction(UIAction { [weak self] _ in self?.loadOriginal() }, for: .touchUpInside)
    captionView.text = captionText
    captionView.font = .systemFont(ofSize: 16)
    captionView.textColor = .white
    captionView.backgroundColor = .clear
    captionView.isEditable = false
    captionView.isSelectable = true
    captionView.textContainerInset = .zero
    captionView.textContainer.lineFragmentPadding = 0
    captionView.showsVerticalScrollIndicator = false
    captionView.accessibilityIdentifier = "viewer.caption"
    captionShade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
    captionView.isHidden = captionText.isEmpty
    captionShade.isHidden = captionText.isEmpty
    view.layer.addSublayer(captionShade)
    view.addSubview(captionView)
    for control in [back, progress, retry] { view.addSubview(control) }
    back.isHidden = embedded
  }
  // Вписываем изображение с учётом поворота файла, сохраняя масштаб и точку под центром при смене
  // размера окна. Кнопки и подпись располагаем отдельно от масштабируемого слоя.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let size = view.bounds.size
    if viewport != size, size.width > 0, size.height > 0 {
      let oldFocus =
        viewport == .zero
        ? CGPoint(x: 0.5, y: 0.5)
        : CGPoint(
          x: (scroll.contentOffset.x + viewport.width / 2) / max(1, scroll.contentSize.width),
          y: (scroll.contentOffset.y + viewport.height / 2) / max(1, scroll.contentSize.height))
      let scale = scroll.zoomScale
      scroll.setZoomScale(1, animated: false)
      scroll.frame = view.bounds
      let w = CGFloat(
        max(1, attachment.orientation >= 5 ? attachment.rawHeight : attachment.rawWidth))
      let h = CGFloat(
        max(1, attachment.orientation >= 5 ? attachment.rawWidth : attachment.rawHeight))
      let fit = min(size.width / w, size.height / h)
      baseSize = CGSize(width: w * fit, height: h * fit)
      viewport = size
      imageHost.frame = CGRect(origin: .zero, size: baseSize)
      scroll.contentSize = baseSize
      scroll.setZoomScale(scale, animated: false)
      centerImage()
      let target = CGPoint(
        x: oldFocus.x * scroll.contentSize.width - size.width / 2,
        y: oldFocus.y * scroll.contentSize.height - size.height / 2)
      scroll.contentOffset = CGPoint(
        x: min(
          max(target.x, -scroll.contentInset.left),
          max(
            -scroll.contentInset.left,
            scroll.contentSize.width - size.width + scroll.contentInset.right)),
        y: min(
          max(target.y, -scroll.contentInset.top),
          max(
            -scroll.contentInset.top,
            scroll.contentSize.height - size.height + scroll.contentInset.bottom)))
    }
    bindImage()
    back.frame = CGRect(x: 12, y: view.safeAreaInsets.top + 4, width: 44, height: 44)
    let control = CGRect(x: view.bounds.midX - 24, y: view.bounds.midY - 24, width: 48, height: 48)
    progress.frame = control
    retry.frame = control
    let captionHeight =
      captionText.isEmpty
      ? 0
      : min(
        180,
        captionView.sizeThatFits(
          CGSize(width: max(1, size.width - 32), height: .greatestFiniteMagnitude)
        ).height)
    captionView.frame = CGRect(
      x: 16, y: size.height - view.safeAreaInsets.bottom - 24 - captionHeight,
      width: max(1, size.width - 32), height: captionHeight)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    captionShade.frame = CGRect(
      x: 0, y: captionView.frame.minY - 24, width: size.width, height: captionHeight + 40)
    CATransaction.commit()
  }
  // Привязываем файл к прямоугольнику показа и выбираем размер подготовленного изображения.
  // Соседу оставляем уменьшенный кадр, а крупный рисунок берём после готовности оригинала и
  // сохранения меньшего.
  private func bindImage() {
    guard !resourcesClosed else { return }
    originalBound = active && hasOriginal && (standbyPreview != nil || slot.loadFailed)
    slot.bind(
      attachment, frame: CGRect(origin: .zero, size: baseSize),
      maxPixel: originalBound ? 2048 : embedded ? 384 : 1024, cornerRadius: 0,
      kind: embedded ? (playbackKey == nil ? .photo : .video) : nil, showControls: false,
      playbackKey: playbackKey, galleryPreview: embedded && !originalBound)
    if let preview {
      self.preview = nil
      slot.seed(preview)
    }
  }
  // Сохраняем уменьшенный кадр из хранилища или текущего слоя на случай ухода со страницы. Кадр
  // больше допустимого размера закрываем, иначе фоновые страницы удерживали бы крупные картинки.
  private func retainStandbyPreview() {
    let limit = embedded ? 384 : 1024
    let candidate =
      media.cachedThumbnail(attachment: attachment, key: ThumbnailKey(maxPixel: limit, gallery: embedded))
      ?? slot.preview()
    guard let candidate else { return }
    guard let image = candidate.image, max(image.width, image.height) <= limit else {
      candidate.close()
      return
    }
    standbyPreview?.close()
    standbyPreview = candidate
  }
  // Добавляем симметричные пустые поля, если рисунок уже или ниже видимой области. Маленькое фото
  // остаётся по центру при любом масштабе.
  private func centerImage() {
    let x = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2),
      y = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
    let insets = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    if scroll.contentInset != insets { scroll.contentInset = insets }
  }
  // Передаём касание галерее для вложенной страницы. В отдельном окне переключаем собственные
  // кнопку выхода, подпись и затемнение вместе.
  @objc private func toggleControls() {
    if embedded {
      onToggleControls?()
      return
    }
    controlsVisible.toggle()
    back.isHidden = !controlsVisible
    captionView.isHidden = captionText.isEmpty || !controlsVisible
    captionShade.isHidden = captionView.isHidden
  }
  // Двойное касание увеличивает выбранное место фотографии, а повтор возвращает общий вид. Для
  // встроенного видео используется его предел масштаба.
  @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
    if scroll.zoomScale > 1.05 {
      scroll.setZoomScale(1, animated: true)
      return
    }
    let p = gesture.location(in: imageHost), scale = min(3, scroll.maximumZoomScale)
    let target = CGRect(
      x: p.x - scroll.bounds.width / (2 * scale), y: p.y - scroll.bounds.height / (2 * scale),
      width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
    scroll.zoom(to: target, animated: true)
  }
  // Оставляем касания внутри подписи самой подписи. Тогда выделение или прокрутка текста не
  // начнут закрывать просмотр.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard let target = touch.view else { return true }
    return !target.isDescendant(of: captionView)
  }
  // Разрешаем вертикальное закрытие только при обычном масштабе и перевесе движения по вертикали.
  // Увеличенное фото должно двигаться внутри страницы, а горизонталь нужна для свайпа галереи.
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer, scroll.zoomScale <= 1.01 else {
      return false
    }
    let velocity = pan.velocity(in: view)
    return abs(velocity.y) > abs(velocity.x)
  }
  // Двигаем изображение за пальцем и закрываем при достаточном расстоянии или скорости. Короткий
  // или отменённый жест возвращает картинку на место.
  @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
    let dy = gesture.translation(in: view).y
    switch gesture.state {
    case .changed: scroll.transform = CGAffineTransform(translationX: 0, y: dy)
    case .ended:
      if abs(dy) > view.bounds.height * 0.16 || abs(gesture.velocity(in: view).y) > 1000 {
        finish()
      } else {
        restorePosition()
      }
    case .cancelled, .failed: restorePosition()
    default: break
    }
  }
  // Плавно убираем смещение изображения после незавершённого закрытия. Фон снова заполняет экран
  // чёрным.
  private func restorePosition() {
    UIView.animate(withDuration: 0.18) {
      self.scroll.transform = .identity
      self.view.backgroundColor = .black
    }
  }
  // У вложенной страницы просим закрыть всю галерею. Отдельное окно отменяет свою загрузку и
  // закрывается само, не позволяя повторному жесту начать второй переход.
  private func finish() {
    guard !dismissing else { return }
    if embedded {
      onRequestDismiss?()
      return
    }
    dismissing = true
    cancelDownload(showRetry: false)
    dismiss(animated: true)
  }
  // Запоминаем появление и начинаем загрузку, если страница активна и оригинал ещё нужен. Ручную
  // отмену уважаем, а общая фотография генерации получает кадр через свой слой.
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    appeared = true
    if active, !sharedStudioPhoto { if !hasOriginal && !downloadPausedByUser { loadOriginal() } }
  }
  // Возвращаем удержанную копию текущего кадра. Галерея может положить её под видео, пока
  // проигрыватель готовит первый кадр.
  func retainedPreview() -> PreparedImage? { slot.preview() }
  // Просим слой достать последний кадр нужного видео по его ключу. Это сохраняет узнаваемое
  // изображение после снятия проигрывателя.
  func showLastVideoFrame() { slot.showSavedPlaybackFrame(for: playbackKey) }
  // Галерея учитывает увеличение перед передачей жеста соседней странице.
  var pageIsZoomed: Bool { scroll.zoomScale > 1.01 }
  // Готовим кнопки страницы и отмечаем загрузку как остановленную вручную. При повторном открытии
  // человек увидит кнопку повтора вместо немедленной передачи.
  func pauseOriginal() {
    loadViewIfNeeded()
    cancelDownload(showRetry: true)
  }
  // При выборе страницы разрешаем крупный кадр или показываем доступный повтор. При уходе
  // отменяем загрузку и оставляем уменьшенное изображение, чтобы следующая страница могла занять
  // память.
  func setPageActive(_ value: Bool) {
    guard !resourcesClosed, active != value else { return }
    active = value
    if sharedStudioPhoto {
      retry.isHidden = !active || !slot.loadFailed
      return
    }
    if value {
      if downloadPausedByUser {
        retry.isHidden = false
      } else if hasOriginal {
        bindImage()
      } else {
        loadOriginal()
      }
    } else {
      cancelDownload(showRetry: false)
      // Соседней странице хватит миниатюры. Освобождаем оригинал до загрузки выбранного кадра.
      if originalBound { slot.clear() }
      if let standbyPreview {
        preview?.close()
        preview = standbyPreview.retained()
      }
      bindImage()
    }
  }
  // Для общей фотографии обновляем её местный слой. В остальных случаях просим хранилище
  // подготовить оригинал, показываем ход передачи и принимаем только ответ с текущим номером
  // попытки.
  private func loadOriginal() {
    guard active, !resourcesClosed else { return }
    downloadPausedByUser = false
    if sharedStudioPhoto {
      retry.isHidden = true
      slot.refresh()
      bindImage()
      return
    }
    hasOriginal = false
    generation += 1
    let ticket = generation
    download?.cancel()
    retry.isHidden = true
    progress.update(progress: nil, visible: !media.hasLocalOriginal(attachment))
    download = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await media.ensureOriginal(
          attachment,
          progress: { [weak self] value in
            guard let self, self.generation == ticket else { return }
            self.progress.update(progress: value > 0 && value < 1 ? value : nil, visible: true)
          })
        guard generation == ticket, !Task.isCancelled else { return }
        download = nil
        hasOriginal = true
        retainStandbyPreview()
        bindImage()
      } catch {
        guard generation == ticket, !Task.isCancelled else { return }
        download = nil
        progress.update(progress: nil, visible: false)
        retry.isHidden = false
        retry.accessibilityLabel = "Не удалось загрузить. Повторить"
      }
    }
  }
  // Останавливаем чтение и меняем номер попытки, чтобы поздний ответ не изменил картинку. Только
  // ручная отмена ставит отметку для кнопки повтора.
  private func cancelDownload(showRetry: Bool) {
    generation += 1
    download?.cancel()
    download = nil
    if showRetry {
      downloadPausedByUser = true
      hasOriginal = false
    }
    progress.update(progress: nil, visible: false)
    retry.isHidden = !showRetry
  }
  // Возвращаем системе слой самого изображения. Кнопки, ход загрузки и подпись остаются своего
  // размера при увеличении фото.
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageHost }
  // Поправляем отступы по новому размеру и сообщаем галерее, увеличена ли фотография. Галерея по
  // этому признаку отдаёт движение пальца самой странице.
  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    centerImage()
    onZoomChanged?(scrollView.zoomScale > 1.01)
  }
  // После исчезновения закрываем подготовку файла и рисунок. Ресурсы прежнего просмотра не
  // остаются привязаны к невидимому окну.
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    closePage()
  }
  // Один раз прекращаем работу и возвращаем удержанные кадры хранилищу. У самостоятельного окна
  // дополнительно освобождаем простаивающие картинки и возвращаем управление ленте.
  func closePage() {
    guard !resourcesClosed else { return }
    resourcesClosed = true
    active = false
    appeared = false
    cancelDownload(showRetry: false)
    preview?.close()
    preview = nil
    standbyPreview?.close()
    standbyPreview = nil
    slot.close()
    if !embedded {
      media.releaseIdleImages()
      let callback = onReturn
      onReturn = nil
      DispatchQueue.main.async { callback?() }
    }
  }
}
