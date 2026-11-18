// Показывает одну картинку или кадр видео в ленте. При смене вложения отменяет старые запросы и
// не даёт размытой копии закрыть чёткую.

import UIKit
@MainActor final class MediaImageSlot {
  private struct BindingAppearance: Equatable {
    let frame: CGRect
    let circular: Bool
    let maxPixel: Int
    let cornerRadius: CGFloat
    let bottomSquare: Bool
    let kind: MessageKind?
    let showControls: Bool
    let studioPhotoDelivery: Bool
    let studioPhotoMaxPixel: Int?
    let showLoadingControl: Bool
    let maskedCorners: CACornerMask?
    let galleryPreview: Bool
  }

  private struct ControlAppearance: Equatable {
    let frame: CGRect
    let playHidden: Bool
    let transferHidden: Bool
    let strokeEnd: CGFloat
    let retry: Bool
  }

  private static let controlBounds = CGRect(x: 0, y: 0, width: 48, height: 48)
  private static let loadingBackground = UIColor(red: 0.84, green: 0.90, blue: 0.86, alpha: 1)
    .cgColor
  private static let clearBackground = UIColor.clear.cgColor
  private static let playPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 20, y: 15), CGPoint(x: 20, y: 33), CGPoint(x: 35, y: 24)])
    path.closeSubpath()
    return path
  }()
  private static let transferRingPath = CGPath(
    ellipseIn: controlBounds.insetBy(dx: 4, dy: 4), transform: nil)
  private static let cancelPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 18, y: 18), CGPoint(x: 30, y: 30)])
    path.addLines(between: [CGPoint(x: 30, y: 18), CGPoint(x: 18, y: 30)])
    return path
  }()
  private static let retryPath: CGPath = {
    let path = CGMutablePath()
    path.addLines(between: [CGPoint(x: 18, y: 9), CGPoint(x: 24, y: 13), CGPoint(x: 18, y: 17)])
    return path
  }()

  let layer = CALayer()
  private let pixels = CALayer()
  private let store: MediaStore
  private var request: MediaCancellation?, tinyRequest: MediaCancellation?,
    videoPreparation: MediaCancellation?
  private var playbackFrameRequest: MediaCancellation?
  private var playbackFrameKey: VideoPlaybackKey?
  private var playbackFrameSequence: UInt64 = 4
  private var attachment: Attachment?, loadAttempt = 0, pixelLimit = 1024
  private(set) var loading = false
  private var failed = false, transferStarted = false
  private var progress: Double = 0
  var loadFailed: Bool { failed }
  private var appearance: BindingAppearance?
  var showsControls: Bool { appearance?.showControls ?? true }
  private var deferred = false
  private var canShowTinyPreview = true
  var awaitingStudioPhoto: Bool {
    appearance?.studioPhotoDelivery == true && (!ready || displayed?.isTinyPreview == true) && !failed
  }
  private let play = CALayer(), triangle = CAShapeLayer()
  private let control = CALayer(), ring = CAShapeLayer(), cross = CAShapeLayer()
  private var controlAppearance: ControlAppearance?
  private var invalidation: UUID?
  private var identity = "", mediaPath = ""
  private var binding: UInt64?
  private var displayed: PreparedImage?
  private var viewport = CGSize.zero
  private var closed = false
  private(set) var ready = false
  var hasSharpFrame: Bool { ready && displayed?.isTinyPreview == false }
  var onReady: (() -> Void)?
  private lazy var mailbox = MediaSurfaceMailbox<PreparedImage>(
    schedule: { DispatchQueue.main.async(execute: $0) },
    render: { [weak self] frame in
      MainActor.assumeIsolated { self?.publish(frame) }
    })
  // Собирает слой картинки, знак запуска и управление загрузкой. Подписывается на очистку
  // хранилища, чтобы снятое медиа исчезло с экрана.
  init(store: MediaStore) {
    self.store = store
    layer.masksToBounds = true
    layer.backgroundColor = UIColor(white: 0.88, alpha: 1).cgColor
    layer.addSublayer(pixels)
    pixels.anchorPoint = .zero
    play.backgroundColor = UIColor.black.withAlphaComponent(0.36).cgColor
    play.cornerRadius = 24
    triangle.fillColor = UIColor.white.cgColor
    triangle.path = Self.playPath
    play.addSublayer(triangle)
    layer.insertSublayer(play, above: pixels)
    control.backgroundColor = UIColor.black.withAlphaComponent(0.42).cgColor
    control.cornerRadius = 24
    layer.addSublayer(control)
    for shape in [ring, cross] {
      shape.frame = Self.controlBounds
      shape.fillColor = UIColor.clear.cgColor
      shape.strokeColor = UIColor.white.cgColor
      shape.lineWidth = 2
      shape.lineCap = .round
      control.addSublayer(shape)
    }
    ring.path = Self.transferRingPath
    updateControl()
    invalidation = store.registerInvalidation { [weak self] in self?.clear() }
  }
  // Обновляет рамку и выбирает вид изображения. Для прежнего файла сохраняет кадр, а для нового
  // отменяет старые ответы. Сначала ищет сохранённый кадр видео, затем обычную миниатюру.
  func bind(
    _ attachment: Attachment, frame: CGRect, circular: Bool = false, maxPixel: Int = 1024,
    cornerRadius: CGFloat = 12, bottomSquare: Bool = false, kind: MessageKind? = nil,
    showControls: Bool = true, studioPhotoDelivery: Bool = false, studioPhotoMaxPixel: Int? = nil,
    showLoadingControl: Bool = true, localOnly: Bool = false, maskedCorners: CACornerMask? = nil,
    playbackKey: VideoPlaybackKey? = nil, galleryPreview: Bool = false
  ) {
    guard !closed else { return }
    let next = BindingAppearance(
      frame: frame, circular: circular, maxPixel: maxPixel, cornerRadius: cornerRadius,
      bottomSquare: bottomSquare, kind: kind, showControls: showControls,
      studioPhotoDelivery: studioPhotoDelivery, studioPhotoMaxPixel: studioPhotoMaxPixel,
      showLoadingControl: showLoadingControl, maskedCorners: maskedCorners, galleryPreview: galleryPreview)
    // Сдвиг сообщения не меняет рисунок внутри плитки. Отложенная загрузка может стать видимой.
    if appearance == next, self.attachment == attachment, playbackFrameKey == playbackKey,
      !identity.isEmpty,
      !deferred || localOnly
    {
      return
    }
    appearance = next
    let background =
      (studioPhotoDelivery || attachment.tinyPreview == nil) && kind != .sticker
      ? Self.loadingBackground : Self.clearBackground
    updateLayerGeometry(
      frame: frame, radius: circular ? min(frame.width, frame.height) / 2 : cornerRadius,
      bottomSquare: bottomSquare, background: background, maskedCorners: maskedCorners)
    var thumbnail =
      store.studioPhotoKey(attachment, maxPixel: studioPhotoMaxPixel)
      ?? ThumbnailKey(maxPixel: maxPixel)
    thumbnail.gallery = galleryPreview
    let changed = viewport != frame.size
    viewport = frame.size
    self.attachment = attachment
    pixelLimit = thumbnail.maxPixel
    updateControl()
    let key = attachment.relativePath + "@" + String(thumbnail.maxPixel)
      + (galleryPreview ? ":gallery" : "")
    if identity == key && playbackFrameKey == playbackKey && (!deferred || localOnly) {
      if changed,
        let p = PhotoPresentation.filling(
          rawWidth: Int(pixels.bounds.width), rawHeight: Int(pixels.bounds.height), orientation: 1,
          width: Double(viewport.width), height: Double(viewport.height))
      {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pixels.setAffineTransform(p.affineTransform)
        CATransaction.commit()
      }
      return
    }
    let preserve = mediaPath == attachment.relativePath && playbackFrameKey == playbackKey
      && displayed != nil
    loadAttempt += 1
    request?.cancel()
    request = nil
    tinyRequest?.cancel()
    tinyRequest = nil
    playbackFrameRequest?.cancel()
    playbackFrameRequest = nil
    playbackFrameKey = nil
    videoPreparation?.cancel()
    videoPreparation = nil
    identity = key
    loading = true
    failed = false
    deferred = false
    // При возврате к истории сначала ждём сохранённый кадр с устройства.
    canShowTinyPreview = kind == nil || kind == .sticker || studioPhotoDelivery
      || store.remoteThumbnailProvider == nil
    transferStarted = false
    progress = 0
    updateControl()
    mediaPath = attachment.relativePath
    if !preserve { ready = false }
    guard let token = mailbox.begin(preservingDisplay: preserve) else { return }
    binding = token
    playbackFrameSequence = 4
    if let playbackKey {
      playbackFrameKey = playbackKey
      if showSavedPlaybackFrame() { return }
      // Заставка нужна только после проверки, что с прошлого просмотра кадра нет.
      playbackFrameRequest = store.videoPlayback.restoreCover(playbackKey) { [weak self] result in
        guard let self, !self.closed, self.binding == token, self.playbackFrameKey == playbackKey
        else {
          if case let .success(frame) = result { frame.close() }
          return
        }
        self.playbackFrameRequest = nil
        if case let .success(frame) = result {
          self.seedPlaybackFrame(frame)
        } else if !self.showSavedPlaybackFrame() {
          self.loadThumbnail(attachment, key: thumbnail, token: token, localOnly: localOnly)
        }
      }
      return
    }
    loadThumbnail(attachment, key: thumbnail, token: token, localOnly: localOnly)
  }

  // Сразу выводит готовую копию или запрашивает её в фоне. Отличает отложенную загрузку от ошибки
  // и принимает ответы только текущей попытки.
  private func loadThumbnail(
    _ attachment: Attachment, key thumbnail: ThumbnailKey, token: UInt64, localOnly: Bool
  ) {
    let attempt = loadAttempt
    if let cached = store.cachedThumbnail(attachment: attachment, key: thumbnail) {
      request = nil
      tinyRequest = nil
      loading = false
      mailbox.offer(cached, binding: token, sequence: 3)
      mailbox.flush()
      updateControl()
      return
    }
    showTinyPreviewIfNeeded()
    request = store.thumbnail(
      attachment: attachment, key: thumbnail, ticket: 0, localOnly: localOnly,
      progress: { [weak self] value in
        guard let self, self.loadAttempt == attempt, !self.closed else { return }
        self.transferStarted = true
        self.progress = value
        self.updateControl()
      },
      localMiss: { [weak self] in
        guard let self, self.loadAttempt == attempt, !self.closed else { return }
        self.canShowTinyPreview = true
        self.showTinyPreviewIfNeeded()
      }
    ) { [weak self] _, result in
      guard let self, self.loadAttempt == attempt, !self.closed else {
        if case let .success(f) = result { f.close() }
        return
      }
      self.request = nil
      self.loading = false
      self.failed = false
      if case let .success(frame) = result {
        self.mailbox.offer(frame, binding: token, sequence: 3)
      } else if localOnly {
        self.deferred = true
      } else {
        self.failed = true
        self.canShowTinyPreview = true
        self.showTinyPreviewIfNeeded()
      }
      self.updateControl()
      self.onReady?()
    }
  }

  private var canPresentTinyPreview: Bool {
    guard canShowTinyPreview, let attachment else { return false }
    return appearance?.galleryPreview != true || !store.wasShownInGallery(attachment)
  }

  // Показывает размытый кадр, пока нет готового и он разрешён для этого вложения. Уже
  // просмотренное в галерее медиа не подменяется такой картинкой снова.
  private func showTinyPreviewIfNeeded() {
    guard canPresentTinyPreview, !ready, playbackFrameRequest == nil, tinyRequest == nil,
      let attachment, let binding
    else { return }
    if let cached = store.cachedTinyPreview(attachment) {
      mailbox.offer(cached, binding: binding, sequence: 1)
      mailbox.flush()
    } else if attachment.tinyPreview != nil {
      tinyRequest = store.tinyPreview(attachment) { [weak self] result in
        guard case let .success(frame) = result else { return }
        guard let self, self.canPresentTinyPreview else { frame.close(); return }
        self.mailbox.offer(frame, binding: binding, sequence: 1)
      }
    }
  }

  // Меняет рамку, углы и фон только при отличиях и без скрытой анимации. Прокрутка не должна
  // заново перестраивать неизменившийся рисунок.
  private func updateLayerGeometry(
    frame: CGRect, radius: CGFloat, bottomSquare: Bool, background: CGColor,
    maskedCorners: CACornerMask?
  ) {
    let corners: CACornerMask =
      maskedCorners ?? (bottomSquare
      ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner])
    let moved = layer.frame != frame
    let radiusChanged = layer.cornerRadius != radius
    let cornersChanged = layer.maskedCorners != corners
    let backgroundChanged = layer.backgroundColor != background
    // Готовый слой уже несёт нужное оформление, пока положение и размеры совпадают.
    guard moved || radiusChanged || cornersChanged || backgroundChanged else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if moved { layer.frame = frame }
    if radiusChanged { layer.cornerRadius = radius }
    if cornersChanged { layer.maskedCorners = corners }
    if backgroundChanged { layer.backgroundColor = background }
    CATransaction.commit()
  }
  // Передаёт действительный кадр слою, вычисляет масштаб заполнения и обновляет готовность. При
  // снятии кадра сразу убирает старые пиксели.
  private func publish(_ frame: PreparedImage?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    pixels.removeAllAnimations()
    displayed = frame
    pixels.contents = nil
    pixels.transform = CATransform3DIdentity
    ready = false
    if let image = frame?.image,
      let p = PhotoPresentation.filling(
        rawWidth: image.width, rawHeight: image.height, orientation: 1,
        width: Double(viewport.width), height: Double(viewport.height))
    {
      pixels.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
      pixels.position = .zero
      pixels.setAffineTransform(p.affineTransform)
      pixels.contents = image
      ready = true
    }
    updateControl()
    onReady?()
  }
  private var hasUsablePhoto: Bool { appearance?.kind == .photo && hasSharpFrame }
  private var hasTransferControl: Bool {
    loading && !hasUsablePhoto && appearance?.studioPhotoDelivery != true
      && (progress > 0
        || (appearance?.showLoadingControl != false && (appearance?.kind == nil || transferStarted)))
  }
  var loadAction: (CGRect, String)? {
    guard showsControls, !hasUsablePhoto, failed || hasTransferControl else { return nil }
    return (
      CGRect(x: layer.frame.midX - 24, y: layer.frame.midY - 24, width: 48, height: 48),
      loading ? "Отменить загрузку" : "Повторить загрузку"
    )
  }
  // Проверяет попадание в кнопку и либо отменяет передачу, либо повторяет запрос с прежней
  // рамкой. Действие относится только к текущему вложению.
  @discardableResult func performLoadAction(at point: CGPoint) -> Bool {
    guard let action = loadAction, action.0.contains(point), !closed else { return false }
    if loading {
      loadAttempt += 1
      request?.cancel()
      request = nil
      loading = false
      failed = true
      updateControl()
      onReady?()
    } else if let attachment, let appearance {
      identity = ""
      bind(
        attachment, frame: appearance.frame, circular: appearance.circular,
        maxPixel: appearance.maxPixel, cornerRadius: appearance.cornerRadius,
        bottomSquare: appearance.bottomSquare, kind: appearance.kind,
        showControls: appearance.showControls, studioPhotoDelivery: appearance.studioPhotoDelivery,
        studioPhotoMaxPixel: appearance.studioPhotoMaxPixel,
        showLoadingControl: appearance.showLoadingControl, maskedCorners: appearance.maskedCorners,
        playbackKey: playbackFrameKey, galleryPreview: appearance.galleryPreview)
    }
    return true
  }
  // Сравнивает прежние кнопки с нужными сейчас и меняет только отличия. Готовое фото не
  // перекрывается кольцом загрузки, а ошибка показывает повтор.
  private func updateControl() {
    let bounds = Self.controlBounds
    let next = ControlAppearance(
      frame: bounds.offsetBy(dx: (viewport.width - bounds.width) / 2,
        dy: (viewport.height - bounds.height) / 2),
      playHidden: !showsControls || appearance?.kind != .video || loading || failed,
      transferHidden: !showsControls || hasUsablePhoto || (!failed && !hasTransferControl),
      strokeEnd: CGFloat(loading ? (progress > 0 ? progress : 0.72) : 0.82),
      retry: failed)
    let previous = controlAppearance
    guard next != previous else { return }
    controlAppearance = next

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    if next.frame != previous?.frame {
      play.frame = next.frame
      control.frame = next.frame
    }
    play.isHidden = next.playHidden
    control.isHidden = next.transferHidden
    ring.strokeEnd = next.strokeEnd
    if next.retry != previous?.retry {
      cross.path = next.retry ? Self.retryPath : Self.cancelPath
    }
  }
  // Ставит раннюю подготовку видео после готовности кадра. Пока идёт загрузка или уже есть
  // подготовка, второй запрос не нужен.
  func prepareOriginalVideo(_ attachment: Attachment) {
    guard ready, !loading, !failed, videoPreparation == nil else { return }
    videoPreparation = store.prepareStudioVideo(attachment)
  }
  // Выдаёт отдельное удержание текущего изображения. Следующий экран сможет закрыть его
  // независимо от этой ячейки.
  func preview() -> PreparedImage? { displayed?.retained() }
  // Проверяет ключ и ищет кадр в памяти. Если он уже показан, закрывает лишнее удержание без
  // замены.
  @discardableResult func showSavedPlaybackFrame(for expectedKey: VideoPlaybackKey? = nil) -> Bool {
    guard !closed, let key = playbackFrameKey, expectedKey == nil || key == expectedKey,
      let frame = store.videoPlayback.cover(key)
    else {
      return false
    }
    if let current = displayed?.image, current === frame.image {
      frame.close()
    } else {
      seedPlaybackFrame(frame)
    }
    return true
  }
  // Отменяет работу над обычной и размытой картинками и ставит сохранённый кадр выше по порядку.
  // Поздний ответ меньшего качества больше не перекроет его.
  func seedPlaybackFrame(_ image: PreparedImage) {
    guard !closed, let binding, image.image != nil else { image.close(); return }
    // Чёткий кадр уже готов, поэтому заставка и её декодирование больше не нужны.
    playbackFrameRequest?.cancel()
    playbackFrameRequest = nil
    loadAttempt += 1
    request?.cancel()
    request = nil
    tinyRequest?.cancel()
    tinyRequest = nil
    loading = false
    failed = false
    deferred = false
    playbackFrameSequence += 1
    mailbox.offer(image, binding: binding, sequence: playbackFrameSequence)
    mailbox.flush()
  }
  // Принимает картинку от соседнего экрана только если она подходит и не хуже готовой. Выбирает
  // порядок по размеру и виду, а ненужное удержание закрывает.
  func seed(_ image: PreparedImage) {
    if playbackFrameRequest != nil || image.isTinyPreview && !canPresentTinyPreview {
      image.close()
      return
    }
    guard let binding, let pixels = image.image else {
      image.close()
      return
    }
    let edge = max(pixels.width, pixels.height)
    if hasSharpFrame, let current = displayed?.image,
      image.isTinyPreview || edge <= max(current.width, current.height)
    {
      image.close()
      return
    }
    let serial: UInt64 = image.isTinyPreview ? 1 : edge >= pixelLimit ? 4 : 2
    mailbox.offer(image, binding: binding, sequence: serial)
    mailbox.flush()
  }
  // Отменяет чтения и сбрасывает признак прежнего запроса. Следующая привязка может загрузить
  // нужный файл заново.
  func refresh() {
    loadAttempt += 1
    playbackFrameRequest?.cancel()
    playbackFrameRequest = nil
    playbackFrameKey = nil
    tinyRequest?.cancel()
    request?.cancel()
    videoPreparation?.cancel()
    videoPreparation = nil
    request = nil
    identity = ""
    loading = false
    failed = false
    updateControl()
  }
  /// Сразу применяет очистку в потоке экрана, чтобы прежняя системная ссылка не оставалась до уведомления.
  // Сбрасывает запросы и сразу убирает кадр в потоке экрана. Системный слой не должен держать его
  // до будущего уведомления.
  func clear() {
    refresh()
    mailbox.clear()
    mailbox.flush()
  }
  /// Удаляет наблюдение хранилища, чтобы сброс медиа больше не обращался к закрытому владельцу.
  // Окончательно останавливает ячейку, снимает слой и подписку. Поздняя очистка хранилища больше
  // не обращается к ушедшему экрану.
  func close() {
    guard !closed else { return }
    closed = true
    refresh()
    mailbox.close()
    mailbox.flush()
    layer.removeFromSuperlayer()
    if let id = invalidation { store.unregisterInvalidation(id) }
    invalidation = nil
  }
}
