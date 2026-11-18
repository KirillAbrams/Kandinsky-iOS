// Сцена истории на айфоне удерживает готовые слои сообщений по их номерам. Прокрутка передвигает
// их без нового рисунка текста. Возле экрана сцена заранее готовит часть фото и кадров, даёт
// движение самым видимым роликам и освобождает остальное.

import UIKit
struct SceneFragment {
  let prepared: PreparedText
  let part: Int
  let frame: CGRect
  // Длинное сообщение может занять несколько фрагментов. Ключ удерживает отдельный слой каждой
  // части.
  var id: FragmentID { FragmentID(messageID: prepared.key.messageID, part: part) }
}
final class SceneSnapshot {
  let ticket: Int
  let fragments: [SceneFragment]
  // Связываем набор фрагментов с номером сцены. Это позволяет принять снимок только в той
  // раскладке, для которой он был собран.
  init(ticket: Int, fragments: [SceneFragment]) {
    self.ticket = ticket
    self.fragments = fragments
  }
}
struct SceneMetrics {
  var recordings = 0
  var liveFragments = 0
  var windowReconciliations = 0
  var activeFrameClocks = 0
}
@MainActor fileprivate final class MediaStampLayer: CALayer {
  var raster: MediaCancellation?, rasterID: UUID?
  var ready = false
  // Создаём прозрачный слой подписи поверх файла и даём ему имя для разбора слоёв. Под ним
  // остаётся сам кадр вложения.
  override init() {
    super.init()
    isOpaque = false
    name = "media.stamp"
  }
  // Позволяем системе создать копию слоя подписи при показе. Она получает свойства исходного слоя
  // через штатное копирование.
  override init(layer: Any) { super.init(layer: layer) }
  // Подпись строится из подготовленного рисунка сцены. Загрузка из файла разметки не создаёт этой
  // связи.
  required init?(coder: NSCoder) { fatalError() }
  // Отменяем подготовку подписи и убираем готовые дочерние рисунки. Сбрасываем номер запроса,
  // чтобы старый результат не накрыл новую подпись.
  func clear() {
    raster?.cancel()
    raster = nil
    rasterID = nil
    ready = false
    contents = nil
    for child in sublayers ?? [] {
      child.contents = nil
      child.removeFromSuperlayer()
    }
  }
}
private struct MediaStampBitmap {
  let frame: CGRect
  let image: CGImage
}
@MainActor final class MessageLayer: CALayer {
  var raster: MediaCancellation?
  var rasterID: UUID?
  var needsStaticRetry = false
  var image: MediaImageSlot?
  var extraImages: [Int: MediaImageSlot] = [:]
  // Закрываем основное изображение и все дополнительные вложения строки. Они больше не удерживают
  // кадры после ухода сообщения.
  func retireImages() {
    image?.close()
    image = nil
    retireExtraImages()
  }
  // Освобождаем рисунки остальных ячеек, сохраняя основное изображение. Это нужно, когда карточка
  // снова показывает один файл.
  func retireExtraImages() {
    for image in extraImages.values { image.close() }
    extraImages.removeAll()
  }
  var video: SilentVideoPreview?
  var albumVideos: [String: SilentVideoPreview] = [:]
  var progressLayers: [String: StudioProgressLayer] = [:]
  // Снимаем ролики с ячеек. При обычном уходе возвращаем их на паузе в общий запас, а при
  // закрытии освобождаем полностью.
  func retireAlbumVideos(keepingPlayers: Bool = false) {
    albumVideos.values.forEach {
      if keepingPlayers { $0.setVisible(false); $0.layer.removeFromSuperlayer() }
      else { $0.close() }
    }
    albumVideos.removeAll()
  }
  // Удаляем индикаторы и их привязки к ячейкам. Иначе старый процент мог бы остаться поверх
  // другого файла.
  func retireProgress() {
    progressLayers.values.forEach { $0.removeFromSuperlayer() }
    progressLayers.removeAll()
  }
  // Переносим готовые рисунки по номерам вложений при изменении их порядка. Кадр остаётся у
  // своего файла, а исчезнувшие файлы освобождаем.
  func preserveAlbumImages(from old: Message, to new: Message) {
    guard old.attachments.map(\.id) != new.attachments.map(\.id) else { return }
    var previous: [String: MediaImageSlot] = [:]
    for (index, attachment) in old.attachments.enumerated() {
      if let slot = index == 0 ? image : extraImages[index] { previous[attachment.id] = slot }
    }
    image = nil
    extraImages.removeAll()
    for (index, attachment) in new.attachments.enumerated() {
      guard let slot = previous.removeValue(forKey: attachment.id) else { continue }
      if index == 0 { image = slot } else { extraImages[index] = slot }
    }
    previous.values.forEach { $0.close() }
  }
  fileprivate var overlay: MediaStampLayer?
  var fragment: SceneFragment?
  var onRecord: (() -> Void)?
  // Создаём прозрачный слой сообщения с подготовкой под управлением сцены. Самостоятельная
  // отрисовка слоя отключена, чтобы работа не дублировалась.
  override init() {
    super.init()
    isOpaque = false
    drawsAsynchronously = false
  }
  // Передаём копирование слоя сообщения системе. Видимая копия продолжает пользоваться его
  // обычными свойствами.
  override init(layer: Any) { super.init(layer: layer) }
  // Сообщение приходит из указателя истории и своего рисунка. В сохранённой разметке такого
  // источника нет.
  required init?(coder: NSCoder) { fatalError() }
}
@MainActor final class RetainedChatScene {
  private let container: CALayer
  // У каждого из ста двадцати восьми фрагментов может быть задача рисунка и небольшая задача подписей
  private let rasterQueue = MediaDecodeQueue(maximumWorkers: 1, maximumPending: 256)
  private var nodes: [FragmentID: MessageLayer] = [:]
  private weak var appliedSnapshot: SceneSnapshot?
  private let imagePrefetch = MediaImagePrefetch()
  private let videoPreviews = SilentVideoPreviewPool()
  var mediaVisible = true {
    // При скрытии файлов останавливаем подготовку и движение, затем освобождаем изображения.
    // Скрытая переписка не продолжает держать готовые кадры активно.
    didSet {
      if !mediaVisible {
        imagePrefetch.clear()
        mediaStore?.videoPlayback.prepareCovers([])
        retireMovingMedia()
        for node in nodes.values { node.retireImages() }
        mediaStore?.releaseIdleImages()
      }
    }
  }
  // При скрытии движения снимаем ролики и индикаторы, а неподвижные картинки оставляем.
  var movingMediaVisible = true { didSet { if !movingMediaVisible { retireMovingMedia() } } }
  // Закрываем ролики и анимированные индикаторы. Возвращаем видимость основному рисунку, чтобы на
  // месте остановившегося видео остался кадр.
  private func retireMovingMedia() {
    videoPreviews.clear()
    for node in nodes.values {
      node.video?.close()
      node.video = nil
      node.retireAlbumVideos()
      node.retireProgress()
      node.image?.layer.isHidden = false
    }
    metrics.activeFrameClocks = 0
  }
  var viewport: CGRect?
  var imageViewport: CGRect?
  var imagePreparationViewport: CGRect?
  private var previewObserver: UUID?
  var mediaStore: MediaStore?
  var onStaticReady: (() -> Void)?
  var onImageReady: (() -> Void)?
  private var closed = false
  private(set) var ticket = 1
  private(set) var metrics = SceneMetrics()
  // Принимаем слой родительской истории и подписываемся на появление свободного места для
  // предварительных показов. Тогда новую попытку можно назначить после освобождения
  // проигрывателя.
  init(container: CALayer) {
    self.container = container
    previewObserver = MediaAdmission.observePreviewAvailability { [weak self] in
      self?.onImageReady?()
    }
  }
  // Принимаем результат только для открытой сцены с текущим номером. Просроченный рисунок
  // закрываем сразу, чтобы он не держал память после смены ширины или истории.
  func accept(_ resource: PreparedText, ticket: Int) -> Bool {
    guard !closed, self.ticket == ticket else {
      resource.close()
      return false
    }
    return true
  }
  // Возвращаем тождество слоя по части сообщения. Проверки так отличают перенос готового слоя от
  // создания другого.
  func nodeIdentity(for id: FragmentID) -> ObjectIdentifier? {
    nodes[id].map { ObjectIdentifier($0) }
  }
  // Для выбранного вложения сначала ищем текущий кадр ролика, затем сохранённый чёткий кадр и
  // готовую картинку строки. Если их нет, пробуем соседний запас, чтобы просмотр не ждал пустого
  // экрана.
  func preview(_ id: MessageID, attachmentIndex: Int = 0) -> PreparedImage? {
    guard let node = nodes[FragmentID(messageID: id, part: 0)] else { return nil }
    if let attachments = node.fragment?.prepared.message.attachments,
      attachments.indices.contains(attachmentIndex) {
      let attachment = attachments[attachmentIndex]
      let video = attachmentIndex == 0 ? node.video ?? node.albumVideos[attachment.id]
        : node.albumVideos[attachment.id]
      if let frame = video?.snapshotFrame() { return frame }
      if let store = mediaStore,
        let frame = store.videoPlayback.cover(VideoPlaybackKey(messageID: id, attachment: attachment)) {
        return frame
      }
    }
    if let shown = (attachmentIndex == 0 ? node.image : node.extraImages[attachmentIndex])?.preview() {
      return shown
    }
    guard let mediaStore, let attachments = node.fragment?.prepared.message.attachments,
      attachments.indices.contains(attachmentIndex) else { return nil }
    let item = MediaImagePrefetch.Item(
      attachment: attachments[attachmentIndex],
      maxPixel: mediaThumbnailLimit(node.fragment?.prepared))
    return imagePrefetch.preview(item, store: mediaStore)
  }
  // Проверяем готовность рисунка отдельного вложения. В альбоме каждый файл может закончить
  // подготовку в своё время.
  func imageReady(_ id: MessageID, attachmentIndex: Int = 0) -> Bool {
    guard let node = nodes[FragmentID(messageID: id, part: 0)] else { return false }
    return (attachmentIndex == 0 ? node.image : node.extraImages[attachmentIndex])?.ready == true
  }
  // Проверяем рисунок и подпись каждого видимого фрагмента. Если открытие ещё ждёт медиа, требуем
  // готовности только для ячеек, которые действительно попали на экран.
  func presentationReady(_ ids: Set<FragmentID>, requireMedia: Bool) -> Bool {
    ids.allSatisfy { id in
      guard let node = nodes[id], let fragment = node.fragment else { return false }
      guard
        node.contents != nil || (fragment.part == 0 && fragment.prepared.mediaOnlyBackground != nil)
      else { return false }
      if fragment.part == 0, fragment.prepared.hasMediaStamp, node.overlay?.ready != true {
        return false
      }
      guard requireMedia, fragment.part == 0 else { return true }
      return fragment.prepared.mediaItemRects.enumerated().allSatisfy { index, local in
        let rect = local.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY)
        guard rect.intersects(imageViewport ?? viewport ?? container.bounds) else { return true }
        let slot = index == 0 ? node.image : node.extraImages[index]
        return slot?.ready == true && slot?.loading == false
      }
    }
  }
  // Собираем доступные повторы загрузки в порядке вложений и переводим их рамки в координаты
  // сцены. Поверх уже играющего одиночного видео такой кнопки нет.
  func loadActions() -> [(MessageID, Int, CGRect, String)] {
    nodes.values.flatMap { node -> [(MessageID, Int, CGRect, String)] in
      guard node.video?.presented != true, let fragment = node.fragment else { return [] }
      var images = node.extraImages
      if let image = node.image { images[0] = image }
      return images.sorted { $0.key < $1.key }.compactMap { index, image in
        guard let action = image.loadAction else { return nil }
        return (
          fragment.id.messageID, index, action.0.offsetBy(dx: node.frame.minX, dy: node.frame.minY),
          action.1
        )
      }
    }
  }
  // Переводим касание в координаты слоя и передаём первой подходящей кнопке. Пропускаем активное
  // видео, чтобы оно само принимало касания.
  @discardableResult func performLoadAction(at point: CGPoint) -> Bool {
    for node in nodes.values where node.video?.presented != true {
      let local = CGPoint(x: point.x - node.frame.minX, y: point.y - node.frame.minY)
      for image in [node.image].compactMap({ $0 }) + Array(node.extraImages.values) {
        if image.performLoadAction(at: local) { return true }
      }
    }
    return false
  }
  // Увеличиваем номер сцены, отменяем прежние задачи и снимаем рисунки, ролики и индикаторы.
  // Результаты старой подготовки больше не применятся к новой геометрии.
  func advanceGeneration() {
    imagePrefetch.clear()
    mediaStore?.videoPlayback.prepareCovers([])
    videoPreviews.clear()
    ticket += 1
    for n in nodes.values {
      n.raster?.cancel()
      n.contents = nil
      n.overlay?.clear()
      n.overlay?.removeFromSuperlayer()
      n.overlay = nil
      n.video?.close()
      n.retireAlbumVideos()
      n.retireProgress()
      n.retireImages()
      n.removeFromSuperlayer()
    }
    nodes.removeAll()
    appliedSnapshot = nil
    metrics.liveFragments = 0
  }
  // Берём видимые фрагменты и до трёх соседних для подготовки медиа, сохраняя место и
  // сзади движения. Переиспользуем слои, выбираем ограниченное число роликов по видимости и
  // сохраняем кадр при паузе. Работа за экраном остаётся ограниченной.
  func apply(_ snapshot: SceneSnapshot) {
    guard !closed, snapshot.ticket == ticket else { return }
    let fragments = snapshot.fragments.prefix(128), view = viewport ?? container.bounds
    let neighbors: [SceneFragment]
    if mediaVisible, let imageViewport, let preparation = imagePreparationViewport {
      let towardOlder = imageViewport.minY - preparation.minY >= preparation.maxY - imageViewport.maxY
      let nearby = fragments.compactMap { fragment -> (fragment: SceneFragment, ahead: Bool, distance: CGFloat)? in
        guard fragment.part == 0, !fragment.prepared.message.attachments.isEmpty,
          let local = fragment.prepared.mediaRect
        else { return nil }
        let rect = local.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY)
        guard preparation.intersects(rect), !imageViewport.intersects(rect) else { return nil }
        return (fragment, towardOlder ? rect.midY < imageViewport.midY : rect.midY > imageViewport.midY,
          abs(rect.midY - imageViewport.midY))
      }
      let ordered = nearby.sorted {
        $0.ahead == $1.ahead ? $0.distance < $1.distance : $0.ahead
      }
      if ordered.count > 3, ordered[2].ahead,
        let behind = ordered.first(where: { !$0.ahead })
      {
        neighbors = [ordered[0].fragment, ordered[1].fragment, behind.fragment]
      } else {
        neighbors = ordered.prefix(3).map(\.fragment)
      }
    } else {
      neighbors = []
    }
    let prefetched = Set(neighbors.map(\.id))
    let videoPreviewsAllowed = mediaVisible && movingMediaVisible && MediaAdmission.previewsAllowed
    var upcomingVideo: (key: VideoPlaybackKey, fraction: CGFloat)?
    // Выбираем самый видимый из подходящих роликов, которые только входят в кадр и уже имеют
    // сохранённую позицию. Подготовка такого ролика использует местный файл и опережает его
    // возврат на экран.
    func considerVideo(_ key: VideoPlaybackKey, fraction: CGFloat) {
      guard fraction >= 0.12, fraction < 0.5, fraction > (upcomingVideo?.fraction ?? 0),
        let mediaStore, mediaStore.videoPlayback.position(key) > 0
      else { return }
      upcomingVideo = (key, fraction)
    }
    let visibleVideos: [SceneFragment]
    if videoPreviewsAllowed, view.width > 0, view.height > 0 {
      let candidates = fragments.compactMap { fragment -> (fragment: SceneFragment, distance: CGFloat)? in
        let message = fragment.prepared.message
        guard fragment.part == 0, fragment.prepared.generationCard?.isBatch != true,
          message.attachments.count == 1, message.kind == .video || message.kind == .round,
          let local = fragment.prepared.mediaRect, let attachment = message.attachments.first
        else { return nil }
        let rect = local.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY)
        let shown = rect.intersection(view)
        guard !shown.isNull, shown.width > 0, rect.height > 0 else { return nil }
        let fraction = shown.height / min(rect.height, view.height)
        if fraction < 0.5 {
          considerVideo(VideoPlaybackKey(messageID: message.id, attachment: attachment),
            fraction: fraction)
          return nil
        }
        return (fragment, abs(rect.midY - view.midY))
      }
      visibleVideos = candidates.sorted { $0.distance < $1.distance }.prefix(2).map(\.fragment)
    } else {
      visibleVideos = []
    }
    let animated = Set(visibleVideos.map(\.id))
    var videoKeys = visibleVideos.compactMap { fragment in
      fragment.prepared.message.attachments.first.map {
        VideoPlaybackKey(messageID: fragment.prepared.message.id, attachment: $0)
      }
    }
    var hasAlbumVideo = false
    if videoPreviewsAllowed, let mediaStore {
      for fragment in fragments where fragment.part == 0 {
        let prepared = fragment.prepared
        guard prepared.mediaItemRects.count > 1 || prepared.generationCard?.isBatch == true else { continue }
        for (index, attachment) in prepared.message.attachments.enumerated()
        where attachment.mime.hasPrefix("video/") && prepared.mediaItemRects.indices.contains(index) {
          guard prepared.generationCard?.isBatch == true || mediaStore.isStudioVideo(attachment) else { continue }
          let frame = prepared.mediaItemRects[index].offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY)
          let shown = frame.intersection(view)
          guard !shown.isNull, frame.height > 0, view.height > 0 else { continue }
          let key = VideoPlaybackKey(messageID: prepared.message.id, attachment: attachment)
          let fraction = shown.height / min(frame.height, view.height)
          if fraction >= 0.5 {
            videoKeys.append(key)
            hasAlbumVideo = true
          } else {
            considerVideo(key, fraction: fraction)
          }
        }
      }
    }
    let upcomingVideoKey = upcomingVideo?.key
    videoPreviews.beginFrame(
      visibleKeys: videoKeys, limit: hasAlbumVideo ? 4 : 2, preparing: upcomingVideoKey)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if appliedSnapshot !== snapshot {
      appliedSnapshot = snapshot
      removeRetiredLayers(keeping: fragments)
    }
    var nearbyImages = 0
    for fragment in fragments {
      let node: MessageLayer
      if let old = nodes[fragment.id] {
        node = old
      } else {
        node = MessageLayer()
        node.onRecord = { [weak self] in self?.metrics.recordings += 1 }
        nodes[fragment.id] = node
        container.addSublayer(node)
      }
      let previousFragment = node.fragment
      let previous = previousFragment?.prepared
      let card = fragment.prepared.generationCard
      let newLayout = previous !== fragment.prepared || previousFragment?.part != fragment.part
      let changed: Bool
      if newLayout {
        let sameInk =
          previous?.generationCard.flatMap { old in card.map { $0.sameStaticInk(as: old) } } == true
        changed =
          (!sameInk && previous?.key != fragment.prepared.key) || previousFragment?.part != fragment.part
        if card?.isBatch == true, let previous, previous.generationCard?.isBatch == true {
          node.preserveAlbumImages(from: previous.message, to: fragment.prepared.message)
        }
        let contentsScale = CGFloat(max(1, fragment.prepared.key.scale))
        if node.contentsScale != contentsScale { node.contentsScale = contentsScale }
      } else {
        changed = false
      }
      // Прокрутка сдвигает уже готовую плоскость. Геометрия слоя относится к координатам истории.
      if newLayout || previousFragment?.frame != fragment.frame {
        if node.frame != fragment.frame { node.frame = fragment.frame }
        node.fragment = fragment
      }
      if newLayout || previousFragment?.frame.size != fragment.frame.size || node.needsStaticRetry {
        reconcileStaticContent(
          fragment, node: node, changed: changed,
          retainContents: previous?.generationCard != nil && card != nil)
      }
      let imageIsNearViewport: Bool
      if let imageViewport, let rect = fragment.prepared.mediaRect {
        imageIsNearViewport =
          rect.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY).intersects(
            imageViewport.insetBy(dx: 0, dy: -20))
      } else {
        imageIsNearViewport = true
      }
      if mediaVisible, imageIsNearViewport, fragment.part == 0,
        (fragment.prepared.mediaItemRects.count > 1
          || fragment.prepared.generationCard?.isBatch == true), let mediaStore
      {
        bindAlbum(
          fragment, node: node, media: mediaStore, preparing: prefetched.contains(fragment.id),
          upcomingVideo: upcomingVideoKey)
      } else if mediaVisible, imageIsNearViewport, fragment.part == 0,
        let rect = fragment.prepared.mediaRect, let a = fragment.prepared.message.attachments.first,
        let mediaStore
      {
        node.retireAlbumVideos(keepingPlayers: true)
        node.retireExtraImages()
        if node.image == nil {
          let image = MediaImageSlot(store: mediaStore)
          image.onReady = { [weak self] in self?.onImageReady?() }
          node.image = image
          node.addSublayer(image.layer)
        }
        let deliveringPhoto =
          mediaStore.studioPhotoKey(a) != nil && fragment.prepared.message.direction == .incoming
          && (previous?.generationCard?.generation.isActive == true
            || node.image?.awaitingStudioPhoto == true)
        let isVideo = [MessageKind.video, .round].contains(fragment.prepared.message.kind)
        let playbackKey = isVideo
          ? VideoPlaybackKey(messageID: fragment.prepared.message.id, attachment: a) : nil
        node.image?.bind(
          a, frame: rect, circular: fragment.prepared.message.kind == .round,
          cornerRadius: fragment.prepared.mediaCornerRadius,
          bottomSquare: fragment.prepared.mediaBottomSquare, kind: fragment.prepared.message.kind,
          showControls: !mediaStore.isStudioVideo(a),
          studioPhotoDelivery: deliveringPhoto,
          showLoadingControl: fragment.prepared.message.kind != .photo,
          localOnly: prefetched.contains(fragment.id), playbackKey: playbackKey)
        if let warm = imagePrefetch.preview(.init(attachment: a), store: mediaStore) { node.image?.seed(warm) }
        if let key = playbackKey, animated.contains(fragment.id) || key == upcomingVideoKey {
          node.video = videoPreviews.preview(key) { SilentVideoPreview(store: mediaStore) }
          if let video = node.video, video.layer.superlayer !== node {
            video.onChange = { [weak self, weak node] in
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              node?.image?.layer.isHidden =
                node?.image?.showsControls == true && node?.video?.presented == true
              CATransaction.commit()
              self?.onImageReady?()
            }
            node.addSublayer(video.layer)
          }
          node.video?.onPausedFrame = { [weak slot = node.image] in
            slot?.showSavedPlaybackFrame(for: key)
          }
          node.video?.bind(
            a, frame: rect, circular: fragment.prepared.message.kind == .round,
            cornerRadius: fragment.prepared.mediaCornerRadius,
            bottomSquare: fragment.prepared.mediaBottomSquare, playbackKey: key,
            localOnly: key == upcomingVideoKey)
        } else {
          node.video?.setVisible(false)
          node.video?.layer.removeFromSuperlayer()
          node.video = nil
          node.image?.showSavedPlaybackFrame(for: playbackKey)
        }
      } else {
        node.video?.setVisible(false)
        node.video?.layer.removeFromSuperlayer()
        node.video = nil
        node.retireAlbumVideos(keepingPlayers: true)
        // За краем экрана оставляем не больше двух готовых слоёв. Видео здесь уже на паузе.
        let kind = fragment.prepared.message.kind
        if mediaVisible, nearbyImages < 2, previous?.key == fragment.prepared.key,
          fragment.prepared.message.attachments.count == 1,
          let image = node.image, image.ready, !image.loading, !image.loadFailed,
          kind == .photo || ((kind == .video || kind == .round) && image.hasSharpFrame),
          let imageViewport, let rect = fragment.prepared.mediaRect,
          imageViewport.insetBy(dx: 0, dy: -min(160, imageViewport.height / 4)).intersects(
            rect.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY))
        {
          nearbyImages += 1
        } else {
          node.retireImages()
        }
      }
      if let image = node.image {
        let hidden = image.showsControls && node.video?.presented == true
        if image.layer.isHidden != hidden { image.layer.isHidden = hidden }
      }
      bindProgress(fragment, node: node, viewport: view)
    }
    CATransaction.commit()
    if let mediaStore {
      let images = neighbors.flatMap { fragment in
        let maxPixel = mediaThumbnailLimit(fragment.prepared)
        return fragment.prepared.message.attachments.map {
          MediaImagePrefetch.Item(attachment: $0, maxPixel: maxPixel)
        }
      }
      imagePrefetch.update(images, store: mediaStore)
      mediaStore.videoPlayback.prepareCovers(neighbors.flatMap { fragment in
        fragment.prepared.message.attachments.filter { $0.mime.hasPrefix("video/") }.map {
          VideoPlaybackKey(messageID: fragment.prepared.message.id, attachment: $0)
        }
      })
    }
    metrics.liveFragments = nodes.count
    metrics.activeFrameClocks = nodes.values.reduce(into: 0) { count, node in
      if node.video?.isPlaying == true { count += 1 }
      for video in node.albumVideos.values where video.isPlaying { count += 1 }
    }
  }
  // Находим фрагменты, которых больше нет в новом окне, отменяем их рисунки и снимаем слои.
  // Ролики, которые можно переиспользовать, остаются в общем запасе на паузе.
  private func removeRetiredLayers(keeping fragments: ArraySlice<SceneFragment>) {
    metrics.windowReconciliations += 1
    let wanted = Set(fragments.map(\.id))
    for id in Array(nodes.keys) where !wanted.contains(id) {
      if let node = nodes.removeValue(forKey: id) {
        node.raster?.cancel()
        node.contents = nil
        node.overlay?.clear()
        node.overlay?.removeFromSuperlayer()
        node.overlay = nil
        node.video?.setVisible(false)
        node.video?.layer.removeFromSuperlayer()
        node.retireAlbumVideos(keepingPlayers: true)
        node.retireProgress()
        node.retireImages()
        node.removeFromSuperlayer()
      }
    }
  }

  // Меняем фон и рисунок при новой разметке или отсутствии готового кадра. Подпись поверх медиа
  // обслуживаем отдельно, чтобы движение видео не заставляло заново рисовать всю строку.
  private func reconcileStaticContent(
    _ fragment: SceneFragment, node: MessageLayer, changed: Bool, retainContents: Bool
  ) {
    node.needsStaticRetry = false
    if fragment.part == 0, let fill = fragment.prepared.mediaOnlyBackground {
      if changed || node.raster != nil || node.contents != nil {
        node.raster?.cancel()
        node.raster = nil
        node.rasterID = nil
        node.contents = nil
        node.backgroundColor = fill
        node.cornerRadius = fragment.prepared.message.kind == .round ? 0 : 17
        node.maskedCorners = [
          .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner
        ]
      }
    } else {
      if changed {
        let fill = fragment.prepared.nativeTextBubbleColor
        node.backgroundColor = fill
        node.cornerRadius = fill == nil ? 0 : 14
        var corners: CACornerMask = []
        if fragment.part == 0 { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if fragment.part == fragment.prepared.blocks.count - 1 {
          corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        }
        node.maskedCorners = corners
      }
      if changed || (node.contents == nil && node.raster == nil) {
        prepareBitmap(fragment, node: node, retainContents: retainContents)
      }
    }
    guard fragment.part == 0, fragment.prepared.hasMediaStamp else {
      node.overlay?.clear()
      node.overlay?.removeFromSuperlayer()
      node.overlay = nil
      return
    }
    let overlay: MediaStampLayer
    if let existing = node.overlay {
      overlay = existing
    } else {
      overlay = MediaStampLayer()
      overlay.zPosition = 1
      node.overlay = overlay
      node.addSublayer(overlay)
    }
    let frame = CGRect(origin: .zero, size: fragment.frame.size)
    if overlay.frame != frame { overlay.frame = frame }
    if changed { overlay.clear() }
    if !overlay.ready, overlay.raster == nil {
      prepareMediaStamp(fragment, node: node, overlay: overlay)
    }
  }
  // Сохраняем индикаторы только у видимых ячеек и удаляем ушедшие. Когда генерация закончилась,
  // но фото ещё готовится к показу, оставляем промежуточный индикатор.
  private func bindProgress(_ fragment: SceneFragment, node: MessageLayer, viewport: CGRect) {
    guard mediaVisible, movingMediaVisible, fragment.part == 0 else {
      node.retireProgress()
      return
    }
    let prepared = fragment.prepared, card = prepared.generationCard
    var keys = Set<String>()
    // Подключаем или обновляем индикатор конкретной ячейки по номеру и рамке. Запоминаем его
    // среди использованных, чтобы удалить только устаревшие после обхода.
    func bind(_ id: String, _ frame: CGRect, _ progress: Int?, deliveringPhoto: Bool = false) {
      guard frame.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY).intersects(viewport)
      else { return }
      keys.insert(id)
      let layer = node.progressLayers[id] ?? StudioProgressLayer()
      if layer.superlayer == nil {
        node.addSublayer(layer)
        node.progressLayers[id] = layer
      }
      layer.bind(
        frame: frame, progress: progress, scale: node.contentsScale,
        deliveringPhoto: deliveringPhoto)
    }
    for cell in card?.runningCells ?? [] { bind(cell.slot.id, cell.frame, cell.slot.progress) }
    for (index, attachment) in prepared.message.attachments.enumerated()
    where prepared.mediaItemRects.indices.contains(index) {
      let image = index == 0 ? node.image : node.extraImages[index]
      if image?.awaitingStudioPhoto == true {
        let id =
          card?.cells.first { $0.slot.blobId == attachment.thumbnailKey }?.slot.id ?? "single"
        bind(id, prepared.mediaItemRects[index], 99, deliveringPhoto: true)
      }
    }
    for id in Array(node.progressLayers.keys) where !keys.contains(id) {
      node.progressLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }
  }
  // Для альбома выбираем ограниченный размер кадра отдельной ячейки. Одиночному вложению нужен
  // больший рисунок, а альбом из таких рисунков занял бы больше памяти.
  private func mediaThumbnailLimit(_ prepared: PreparedText?) -> Int {
    guard let prepared,
      prepared.mediaItemRects.count > 1 || prepared.generationCard?.isBatch == true
    else { return 1024 }
    return MediaImagePrefetch.albumMaxPixel
  }

  // Для каждой нужной ячейки привязываем файл, поля и сохранённое изображение. Подходящий видимый
  // ролик пользуется общим проигрывателем, остальные оставляют кадр. Ушедшие ячейки освобождаем.
  private func bindAlbum(
    _ fragment: SceneFragment, node: MessageLayer, media: MediaStore, preparing: Bool,
    upcomingVideo: VideoPlaybackKey?
  ) {
    node.video?.setVisible(false)
    node.video?.layer.removeFromSuperlayer()
    node.video = nil
    let prepared = fragment.prepared, rects = prepared.mediaItemRects, bounds = prepared.mediaRect!
    var wanted = Set<Int>(), playing = Set<String>()
    for (index, rect) in rects.enumerated() {
      if !preparing, let viewport = imageViewport,
        !rect.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY).intersects(
          viewport.insetBy(dx: 0, dy: -20))
      {
        continue
      }
      wanted.insert(index)
      let slot: MediaImageSlot
      if index == 0 {
        if node.image == nil { node.image = MediaImageSlot(store: media) }
        slot = node.image!
      } else {
        if node.extraImages[index] == nil { node.extraImages[index] = MediaImageSlot(store: media) }
        slot = node.extraImages[index]!
      }
      if slot.layer.superlayer !== node {
        node.addSublayer(slot.layer)
        slot.onReady = { [weak self] in self?.onImageReady?() }
      }
      let attachment = prepared.message.attachments[index],
        kind: MessageKind = attachment.mime.hasPrefix("video/") ? .video : .photo
      let studioVideo =
        kind == .video
        && (prepared.generationCard?.isBatch == true || media.isStudioVideo(attachment))
      let slotID = prepared.generationCard?.cells.first {
        $0.slot.blobId == attachment.thumbnailKey
      }?.slot.id
      let deliveringPhoto =
        prepared.message.direction == .incoming && media.studioPhotoKey(attachment) != nil
        && (slot.awaitingStudioPhoto || slotID.map { node.progressLayers[$0] != nil } == true)
      let cellPixelLimit = MediaImagePrefetch.albumMaxPixel
      var corners: CACornerMask = []
      if rect.minY == bounds.minY {
        if rect.minX == bounds.minX { corners.insert(.layerMinXMinYCorner) }
        if rect.maxX == bounds.maxX { corners.insert(.layerMaxXMinYCorner) }
      }
      if !prepared.mediaBottomSquare, rect.maxY == bounds.maxY {
        if rect.minX == bounds.minX { corners.insert(.layerMinXMaxYCorner) }
        if rect.maxX == bounds.maxX { corners.insert(.layerMaxXMaxYCorner) }
      }
      let playbackKey = kind == .video
        ? VideoPlaybackKey(messageID: prepared.message.id, attachment: attachment) : nil
      slot.bind(
        attachment, frame: rect, maxPixel: cellPixelLimit, cornerRadius: 15, kind: kind,
        showControls: !studioVideo,
        studioPhotoDelivery: deliveringPhoto,
        showLoadingControl: kind != .photo, localOnly: preparing, maskedCorners: corners,
        playbackKey: playbackKey)
      if let warm = imagePrefetch.preview(
        .init(attachment: attachment, maxPixel: cellPixelLimit), store: media)
      { slot.seed(warm) }
      if let key = playbackKey {
        let frame = rect.offsetBy(dx: fragment.frame.minX, dy: fragment.frame.minY)
        let shown = frame.intersection(viewport ?? container.bounds)
        if studioVideo, movingMediaVisible, MediaAdmission.previewsAllowed,
          !shown.isNull,
          key == upcomingVideo
            || shown.height >= min(frame.height, (viewport ?? container.bounds).height) * 0.5
        {
          playing.insert(attachment.id)
          if let video = videoPreviews.preview(key, create: { SilentVideoPreview(store: media) }) {
            node.albumVideos[attachment.id] = video
            if video.layer.superlayer !== node {
              node.addSublayer(video.layer)
              video.onChange = { [weak self] in self?.onImageReady?() }
            }
            video.onPausedFrame = { [weak slot] in slot?.showSavedPlaybackFrame(for: key) }
            video.bind(
              attachment, frame: rect, circular: false, cornerRadius: 12, bottomSquare: false,
              studioAlbum: true, playbackKey: key, localOnly: key == upcomingVideo)
          }
        } else if !preparing {
          slot.showSavedPlaybackFrame(for: key)
          slot.prepareOriginalVideo(attachment)
        }
      }
    }
    for id in Array(node.albumVideos.keys) where !playing.contains(id) {
      if let video = node.albumVideos.removeValue(forKey: id) {
        video.setVisible(false)
        video.layer.removeFromSuperlayer()
      }
    }
    if !wanted.contains(0) {
      node.image?.close()
      node.image = nil
    }
    for index in Array(node.extraImages.keys) where !wanted.contains(index) {
      node.extraImages.removeValue(forKey: index)?.close()
    }
  }
  // Объединяем пересекающиеся рамки подписей, чтобы прозрачность не накладывалась дважды, и
  // готовим рисунки в общей фоновой очереди. Перед показом сверяем слой, номер сцены и конкретный
  // запрос.
  private func prepareMediaStamp(
    _ fragment: SceneFragment, node: MessageLayer, overlay: MediaStampLayer
  ) {
    let requestID = UUID(), ticket = self.ticket, prepared = fragment.prepared,
      scale = CGFloat(max(1, fragment.prepared.key.scale))
    overlay.rasterID = requestID
    // Подписи используют ту же очередь, что и рисунки сообщений, без отдельного работника или источника кадров
    overlay.raster = rasterQueue.submit(
      priority: fragment.frame.intersects(imageViewport ?? viewport ?? container.bounds) ? 1 : 0,
      work: {
        var frames: [CGRect] = []
        for region in prepared.mediaOverlayRegions {
          var frame = region.insetBy(dx: -1, dy: -1).applying(
            CGAffineTransform(scaleX: scale, y: scale)
          ).integral.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
          // В узком сообщении подписи могут пересекаться, поэтому общую область рисуем один раз для
          // сохранения прозрачности
          while let index = frames.firstIndex(where: { $0.intersects(frame) }) {
            frame = frame.union(frames.remove(at: index))
          }
          frames.append(frame)
        }
        return try frames.map { frame in
          let width = Int((frame.width * scale).rounded()),
            height = Int((frame.height * scale).rounded())
          guard width > 0, height > 0, width <= 4096, height <= 4096,
            let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else { throw MediaError.unavailable }
          context.translateBy(x: 0, y: CGFloat(height))
          context.scaleBy(x: scale, y: -scale)
          context.translateBy(x: -frame.minX, y: -frame.minY)
          prepared.drawMediaStamp(in: context)
          guard let image = context.makeImage() else { throw MediaError.unavailable }
          return MediaStampBitmap(frame: frame, image: image)
        }
      }, dispose: { _ in },
      completion: { [weak self, weak node, weak overlay] result in
        MainActor.assumeIsolated {
          guard let self, let node, let overlay, !self.closed, self.ticket == ticket,
            self.nodes[fragment.id] === node, node.overlay === overlay,
            overlay.rasterID == requestID
          else { return }
          overlay.raster = nil
          overlay.rasterID = nil
          guard case let .success(bitmaps) = result else {
            node.needsStaticRetry = true
            return
          }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          for bitmap in bitmaps {
            let layer = CALayer()
            layer.frame = bitmap.frame
            layer.contentsScale = scale
            layer.contents = bitmap.image
            overlay.addSublayer(layer)
          }
          overlay.ready = true
          CATransaction.commit()
          self.onStaticReady?()
        }
      })
  }
  // Готовим неподвижную часть сообщения в фоне с пределом размеров рисунка. Для меняющейся
  // карточки можно показать старую версию до новой, чтобы не было пустого кадра. Устаревший ответ
  // отсекаем по номеру и слою.
  private func prepareBitmap(_ fragment: SceneFragment, node: MessageLayer, retainContents: Bool) {
    node.raster?.cancel()
    if !retainContents { node.contents = nil }
    let requestID = UUID(), ticket = self.ticket, prepared = fragment.prepared, part = fragment.part
    let scale = CGFloat(max(1, prepared.key.scale)), size = fragment.frame.size,
      drawsBackground = prepared.nativeTextBubbleColor == nil
    node.rasterID = requestID
    node.raster = rasterQueue.submit(
      priority: fragment.frame.intersects(imageViewport ?? viewport ?? container.bounds) ? 1 : 0,
      work: {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width <= 4096, height <= 4096,
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw MediaError.unavailable }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        prepared.draw(part: part, in: context, drawsBackground: drawsBackground)
        guard let image = context.makeImage() else { throw MediaError.unavailable }
        return image
      }, dispose: { _ in },
      completion: { [weak self, weak node] result in
        MainActor.assumeIsolated {
          guard let self, let node, !self.closed, self.ticket == ticket,
            self.nodes[fragment.id] === node, node.rasterID == requestID
          else { return }
          node.raster = nil
          node.rasterID = nil
          guard case let .success(image) = result else {
            // Если оставлен прежний рисунок, изменение версии запустит следующую подготовку.
            if node.contents == nil { node.needsStaticRetry = true }
            return
          }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          node.contents = image
          CATransaction.commit()
          node.onRecord?()
          self.onStaticReady?()
        }
      })
  }
  // Прекращаем подготовку и освобождаем кадры, подписку на просмотр и очередь рисунков. После
  // закрытия сцена не принимает ответы и не держит часы проигрывания.
  func close() {
    guard !closed else { return }
    onStaticReady = nil
    advanceGeneration()
    closed = true
    rasterQueue.close()
    if let previewObserver { MediaAdmission.removePreviewObserver(previewObserver) }
    previewObserver = nil
    metrics.activeFrameClocks = 0
  }
}
