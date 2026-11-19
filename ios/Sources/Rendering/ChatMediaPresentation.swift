// Показ файлов в ленте на айфоне связывает касание сообщения, полноэкранный просмотр и общий
// проигрыватель. Один экран владеет поверхностью в каждый момент. При возврате она получает
// готовый снимок, пока видео снова занимает своё место.

import UIKit

extension ChatScrollHost {
  // Передаём вместе с сообщением номер выбранного вложения. Сбрасываем временный номер после
  // вызова, чтобы следующий альбом не открылся на чужой позиции.
  func activateMedia(_ row: Message, frame: CGRect, index: Int = 0) {
    tappedMediaIndex = index
    defer { tappedMediaIndex = 0 }
    onMessageTap?(row, frame)
  }

  // Для увеличения сразу открываем просмотр, а для сохранения и передачи сначала получаем
  // оригинал. Системное окно показываем только поверх живого чата без другого открытого окна.
  func performMediaAction(_ action: KandinskyMediaAction, row: Message, frame: CGRect) {
    if action == .expand {
      activateMedia(row, frame: frame)
      return
    }
    guard mediaExport == nil, let media = viewerMedia, let attachment = row.attachments.first else {
      return
    }
    mediaExport = Task { [weak self] in
      defer { self?.mediaExport = nil }
      do {
        let file = try await media.ensureOriginal(attachment)
        try Task.checkCancellation()
        guard let self, !self.closed, let presenter = self.window?.rootViewController,
          presenter.presentedViewController == nil
        else { return }
        switch action {
        case .save:
          presenter.present(
            UIDocumentPickerViewController(forExporting: [file], asCopy: true), animated: true)
        case .share:
          let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
          sheet.popoverPresentationController?.sourceView = self
          sheet.popoverPresentationController?.sourceRect = frame.offsetBy(
            dx: 0, dy: self.contentOffset.y)
          presenter.present(sheet, animated: true)
        case .expand: break
        }
      } catch { if !Task.isCancelled { self?.onError?(error) } }
    }
  }

  // Закрепляем поверхность за лентой и принимаем обновления только от её показа. Касание файла
  // открывает галерею или отдельное фото. На возврате проверяем, что закрывается именно тот
  // просмотр, который был открыт.
  func configurePlayback(_ coordinator: MediaCoordinator, media: MediaStore) {
    coordinator.presentationOwner = playbackOwner
    playback = coordinator
    viewerMedia = media
    playerSurface = InlinePlayerSurface(coordinator: coordinator)
    coordinator.onChange = { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      guard coordinator.presentationOwner == self.playbackOwner else { return }
      self.playerSurface?.update()
      self.studioPreview?.update()
      self.schedule()
    }
    coordinator.onDetachOutput = { [weak self, weak coordinator] in
      guard let self, let coordinator, coordinator.presentationOwner == self.playbackOwner else {
        return
      }
      self.playerSurface?.detach()
      self.playerSurface?.removeFromSuperview()
      self.plane.accessibilityElements?.removeAll { ($0 as? UIView) === self.playerSurface }
      self.studioPreview?.close(animated: false)
    }
    onMessageTap = { [weak self] row, _ in
      guard let self, !self.closed, let a = row.attachments.first else { return }
      if [.photo, .video, .round, .gif].contains(row.kind), self.repository != nil {
        self.openMediaGallery(row, attachmentIndex: self.tappedMediaIndex)
        return
      }
      guard a.mime.hasPrefix("image/") else { return }
      if self.photoViewer == nil, let presenter = self.window?.rootViewController {
        let preview = self.scene.preview(row.id)
        coordinator.stop()
        self.setMediaVisible(false)
        let viewer = PhotoViewerController(
          attachment: a, media: media, preview: preview, caption: row.caption)
        self.photoViewer = viewer
        viewer.onReturn = { [weak self, weak viewer] in
          guard let self, let viewer, self.photoViewer === viewer else { return }
          self.photoViewer = nil
          self.setMediaVisible(true)
        }
        presenter.present(viewer, animated: true)
      }
    }
  }

  // Открываем галерею на выбранном файле с готовым кадром из ленты. Для результата генерации
  // оставляем неподвижную ленту под просмотром, а для обычных файлов убираем её медиа целиком. На
  // возврате восстанавливаем прежнее разрешение движения.
  private func openMediaGallery(_ row: Message, attachmentIndex: Int = 0) {
    guard mediaGallery == nil, photoViewer == nil, let repository, let media = viewerMedia,
      let playback, let surface = playerSurface, let presenter = window?.rootViewController
    else { return }
    let viewer = MediaGalleryController(
      seed: row, repository: repository, media: media, playback: playback, surface: surface,
      preview: scene.preview(row.id, attachmentIndex: attachmentIndex),
      attachmentIndex: attachmentIndex)
    mediaGallery = viewer
    viewer.onDeleteResult = onStudioResultDelete
    let studio = onStudioResultDelete != nil, wasMoving = scene.movingMediaVisible
    if studio {
      viewer.modalPresentationStyle = .overFullScreen
      setMovingMediaVisible(false)
    } else {
      media.withNavigationCache { setMediaVisible(false) }
    }
    if row.kind != .video { playback.stop() }
    viewer.onReturn = { [weak self, weak viewer] in
      guard let self, !self.closed, let viewer, self.mediaGallery === viewer else { return }
      self.mediaGallery = nil
      self.setMediaVisible(true)
      if studio { self.setMovingMediaVisible(wasMoving) }
    }
    presenter.present(viewer, animated: true)
  }

  // Показываем загруженный исходный ролик по кругу перед улучшением. После закрытия останавливаем
  // только этот источник, возвращаем видимость и передаём выбранное продолжение.
  func previewStudioVideo(
    _ attachment: Attachment, onEnhance: (() -> Void)? = nil, onClose: @escaping () -> Void
  ) {
    guard let coordinator = playback, let surface = playerSurface,
      let presenter = window?.rootViewController,
      presenter.presentedViewController == nil, studioPreview == nil
    else {
      onClose()
      return
    }
    setMovingMediaVisible(false)
    coordinator.play(
      target: PlaybackTarget(attachment: attachment, messageID: -1, kind: .video, loopPreview: true)
    )
    surface.circular = false
    surface.setPoster(nil)
    let controller = StudioUploadPreview(
      surface: surface, player: coordinator, attachment: attachment, canEnhance: onEnhance != nil
    ) { [weak self] enhancing in
      self?.studioPreview = nil
      if coordinator.currentMessageID == -1 { coordinator.stop() }
      self?.setMovingMediaVisible(true)
      self?.setMediaVisible(true)
      if enhancing, let onEnhance { onEnhance() } else { onClose() }
    }
    studioPreview = controller
    presenter.present(controller, animated: true)
  }

  // Находим видимую рамку вложения через указатель и готовые размеры строки. При переносе
  // подставляем сохранённый кадр и ставим поверхность в нужную рамку. Вне экрана останавливаем
  // показ.
  func updateInlinePlayer() {
    guard mediaGallery == nil, studioPreview == nil, let coordinator = playback,
      let id = coordinator.currentMessageID, let surface = playerSurface
    else { return }
    guard coordinator.presentationOwner == playbackOwner else {
      surface.detach()
      surface.removeFromSuperview()
      return
    }
    guard let row = loaded[id], let top = index.top(of: id) else {
      hideInlinePlayer()
      return
    }
    let y = CGFloat(top)
    if y + CGFloat(index.height(of: id) ?? 0) <= viewportOffsetY
      || y >= viewportOffsetY + bounds.height
    {
      hideInlinePlayer()
      return
    }
    guard let prepared = cache.value(key(row)) else { return }
    let x = rowLeft(row, prepared)
    var local =
      prepared.mediaRect
      ?? CGRect(
        x: 0, y: 0, width: prepared.width,
        height: row.kind == .voice ? 60 : max(64, min(110, prepared.height)))
    if row.kind == .round { local.size.width = prepared.width }
    let rect = local.offsetBy(dx: x, dy: y)
    guard rect.maxY > viewportOffsetY, rect.minY < viewportOffsetY + bounds.height else {
      hideInlinePlayer()
      return
    }
    if surface.superview !== plane {
      surface.setPoster(scene.preview(id))
      plane.addSubview(surface)
    }
    surface.frame = rect
    surface.circular = row.kind == .round
    surface.attach()
  }

  // Снимаем поверхность со строки. Останавливаем проигрыватель, только если это всё ещё
  // воспроизведение ленты.
  private func hideInlinePlayer() {
    guard let c = playback else { return }
    playerSurface?.detach()
    playerSurface?.removeFromSuperview()
    if c.presentationOwner == playbackOwner {
      c.stop()
    }
  }

  // При закрытии уносим поверхность и освобождаем подписки, владение и воспроизведение, если они
  // принадлежат этому чату. Другой экран может уже использовать общий проигрыватель.
  func retirePlayerPresentation() {
    guard let c = playback else { return }
    playerSurface?.detach()
    playerSurface?.removeFromSuperview()
    if c.presentationOwner == playbackOwner {
      c.onChange = nil
      c.onDetachOutput = nil
      c.presentationOwner = nil
      c.stop()
    }
  }

  // Разрешаем файлы только для активной сцены без отдельного просмотра поверх чата. При потере
  // видимости также заканчиваем инерцию и измерение, чтобы скрытая область не двигалась.
  func setMediaVisible(_ visible: Bool) {
    if !visible {
      interruptCompositorFlight()
      frameProbe.stop()
    }
    scene.mediaVisible =
      !closed && visible && photoViewer == nil && studioPreview == nil && mediaGallery == nil
      && window?.windowScene?.activationState == .foregroundActive
    schedule()
  }

  // Останавливаем движение перед переходом и запрещаем показ новых кадров. Подготовленные
  // неподвижные изображения остаются доступными для возврата.
  func pauseForNavigation() {
    interruptCompositorFlight()
    setContentOffset(contentOffset, animated: false)
    setMovingMediaVisible(false)
  }

  // Отдельно разрешаем движущиеся файлы, учитывая уже открытые просмотры. Назначаем новый кадр,
  // чтобы убрать или вернуть индикаторы вместе с роликами.
  func setMovingMediaVisible(_ visible: Bool) {
    scene.movingMediaVisible =
      !closed && visible && studioPreview == nil && mediaGallery?.onDeleteResult == nil
    schedule()
  }

  // Подключаем хранилище к сцене и просим новый кадр при готовности изображения. Так готовый файл
  // появится даже без движения пальца.
  func configureMedia(_ store: MediaStore) {
    scene.mediaStore = store
    scene.onImageReady = { [weak self] in self?.schedule() }
  }
}
