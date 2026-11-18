import UIKit

extension ChatScrollHost {
  /// На время вызова сохраняет этот номер, чтобы альбом открылся на нужной фотографии или видео.
  func activateMedia(_ row: Message, frame: CGRect, index: Int = 0) {
    tappedMediaIndex = index
    defer { tappedMediaIndex = 0 }
    onMessageTap?(row, frame)
  }

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

  /// Проверяет владельца представления, чтобы другой экран не изменял чужую поверхность воспроизведения.
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

  /// На время просмотра согласует видимость медиа в чате, а после закрытия восстанавливает её только для
  /// того же окна просмотра.
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
      setMediaVisible(false)
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

  /// После закрытия останавливает этот просмотр, восстанавливает видимость чата и вызывает подходящее
  /// продолжение.
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

  private func hideInlinePlayer() {
    guard let c = playback else { return }
    playerSurface?.detach()
    playerSurface?.removeFromSuperview()
    if c.presentationOwner == playbackOwner {
      c.stop()
    }
  }

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

  /// Учитывает открытый просмотр поверх чата, чтобы одни и те же ресурсы не показывались одновременно в двух
  /// местах.
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

  /// Используется при переходах между чатами, чтобы скрытый экран не продолжал движение.
  func pauseForNavigation() {
    interruptCompositorFlight()
    setContentOffset(contentOffset, animated: false)
    setMovingMediaVisible(false)
  }

  /// Запрашивает согласование, чтобы активные поверхности и индикаторы соответствовали новому состоянию.
  func setMovingMediaVisible(_ visible: Bool) {
    scene.movingMediaVisible =
      !closed && visible && studioPreview == nil && mediaGallery?.onDeleteResult == nil
    schedule()
  }

  func configureMedia(_ store: MediaStore) {
    scene.mediaStore = store
    scene.onImageReady = { [weak self] in self?.schedule() }
  }
}
