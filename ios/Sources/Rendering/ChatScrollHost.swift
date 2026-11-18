// Область истории на айфоне владеет сценой, подготовкой строк, показом файлов и состоянием
// прокрутки. Поступающие изменения сходятся к ближайшему кадру. При уходе закрываем чтение и
// освобождаем просмотр, чтобы скрытая лента не продолжала работу.

import UIKit
@MainActor private final class SceneRenderTick: NSObject {
  let action: (CADisplayLink) -> Void
  // Сохраняем действие, которое нужно вызвать в такт обновлению дисплея. Посредник даёт экрану
  // передать это действие без сильной ссылки на себя.
  init(action: @escaping (CADisplayLink) -> Void) { self.action = action }
  // Передаём время кадра назначенному действию. Оно решает, требуется ли перестроить сцену
  // сейчас.
  @objc func tick(_ link: CADisplayLink) { action(link) }
}
@MainActor final class ChatScrollHost: UIScrollView {
  // При новом указателе сбрасываем готовое окно. Старые строки уже могут стоять на другой высоте.
  var index = HistoryIndex(dayGap: 36) { didSet { preparedRowWindow = nil } }
  let days = ScrollingDays()
  var overlayTop: CGFloat = 0, overlayBottom: CGFloat = 0
  var pageRequests = 0
  let frameProbe = ScrollFrameProbe()
  let motionProbe = ScrollMotionProbe()
  let plane = UIView()
  var onStudioResultDelete: ((MessageID, String) -> Void)?
  var onStudioGenerationAction: ((MessageID, StudioGenerationAction) -> Void)?
  var onStudioRetrySlot: ((MessageID, StudioGeneration.Slot) -> Void)?
  struct AccessibilityEntry {
    let key: TextLayoutKey?
    let element: UIAccessibilityElement
  }
  var accessibilityEntries: [String: AccessibilityEntry] = [:]
  var accessibilityUsed = Set<String>()
  lazy var scene = RetainedChatScene(container: plane.layer)
  let worker = TextLayoutWorker(), cache = FragmentLayoutCache()
  #if DEBUG
    var onPreparedRowLookup: ((MessageID) -> Void)?
    var onLayoutPriorityDistance: ((MessageID) -> Void)?
  #endif
  var preparation = ScrollPreparationWindow()
  let scrollClock: () -> TimeInterval
  let canUseCompositorInertia: Bool
  var pendingCompositorTrajectory: ChatInertiaTrajectory?
  var compositorFlight: ChatInertiaFlight?
  var pages: PageWindow?
  var repository: ChatRepository?
  var chatID: ChatID?
  // Подмена сообщений сбрасывает окно готовых строк, чтобы следующая отрисовка взяла свежую
  // редакцию.
  var loaded: [MessageID: Message] = [:] { didSet { preparedRowWindow = nil } }
  var preparedRowWindow: PreparedChatRowWindow?
  var inFlight: [TextLayoutKey: TextLayoutCancellation] = [:]
  var pendingHeights: [MessageID: (key: TextLayoutKey, height: Double)] = [:]
  var pageTask: Task<Void, Never>?
  var queued = false, applying = false, closed = false
  private var renderLink: CADisplayLink?
  private lazy var renderTick = SceneRenderTick { [weak self] link in
    self?.renderScheduledFrame(link)
  }
  var lastSize = CGSize.zero
  private var layoutFontSize = 0
  var generation = 0
  weak var playback: MediaCoordinator?
  var viewerMedia: MediaStore?
  var playerSurface: InlinePlayerSurface?
  var studioPreview: StudioUploadPreview?
  var photoViewer: PhotoViewerController?
  var mediaGallery: MediaGalleryController?
  private var memoryObserver: NSObjectProtocol?
  var initialIndexReady = false
  var initialFrame: CheckedContinuation<Void, Error>?
  var initialMediaDeadline: TimeInterval = 0
  var initialTimeout: DispatchWorkItem?
  var pendingAnchor: ReadingAnchor?
  var metadataTask: Task<Void, Never>?
  // Учитываем размер текста из настроек доступности при новом измерении.
  private var desiredFontSize: Int {
    Int(UIFontMetrics.default.scaledValue(for: 18, compatibleWith: traitCollection).rounded())
  }
  // Используем размер последней раскладки. До первого измерения берём текущее системное значение.
  var fontSize: Int { layoutFontSize > 0 ? layoutFontSize : desiredFontSize }

  let playbackOwner = UUID()
  var tappedMediaIndex = 0
  var mediaExport: Task<Void, Never>?
  var onAnchor: ((ReadingAnchor) -> Void)?
  var onMessageTap: ((Message, CGRect) -> Void)?
  var onMessageLongPress: ((Message, CGRect) -> Void)?
  var onCountChanged: ((Int) -> Void)?
  var onMessageAction: ((Message, MessageAction) -> Void)?
  var onError: ((Error) -> Void)?
  // Возвращаем число сообщений в указателе, включая ещё не прочитанные порции.
  var messageCount: Int { index.rows.count }
  // Отдаём последние замеры сцены владельцу истории и проверкам.
  var metrics: SceneMetrics { scene.metrics }
  // Считаем удерживаемые сообщения в окне. До первого окна используем число уже известных
  // сообщений.
  var loadedCount: Int { pages?.loadedCount ?? loaded.count }
  // Настраиваем системную прокрутку, слой истории и жесты. Часы и разрешение собственной инерции
  // приходят при создании, чтобы проверки могли управлять временем. Предупреждение о памяти
  // сокращает объём уже подготовленных строк.
  init(
    scrollClock: @escaping () -> TimeInterval = CACurrentMediaTime,
    canUseCompositorInertia: Bool =
      ProcessInfo.processInfo.environment["KANDINSKY_COMPOSITOR_INERTIA"] != "0"
  ) {
    self.scrollClock = scrollClock
    self.canUseCompositorInertia = canUseCompositorInertia
    super.init(frame: .zero)
    backgroundColor = .clear
    alwaysBounceVertical = true
    keyboardDismissMode = .interactive
    contentInsetAdjustmentBehavior = .never
    delegate = self
    accessibilityIdentifier = "chat.history"
    plane.backgroundColor = .clear
    plane.isUserInteractionEnabled = true
    delaysContentTouches = false
    addSubview(plane)
    if canUseCompositorInertia {
      let firstTouch = ChatInertiaTouch()
      firstTouch.host = self
      firstTouch.cancelsTouchesInView = false
      firstTouch.delaysTouchesBegan = false
      firstTouch.delaysTouchesEnded = false
      addGestureRecognizer(firstTouch)
    }
    memoryObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.trimMemory() } }
    let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    tap.delegate = self
    addGestureRecognizer(tap)
    let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
    press.delegate = self
    addGestureRecognizer(press)
  }
  // Останавливаем связь с дисплеем, снимаем системное наблюдение и закрываем подготовку текста.
  // Это освобождает обработчики и при уничтожении области.
  deinit {
    renderLink?.invalidate()
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    worker.close()
  }
  // Запрещаем восстановление области из файла разметки. Её слой, жесты и часы устанавливаются при
  // обычном создании из кода.
  required init?(coder: NSCoder) { fatalError() }
  // Просим новую раскладку при смене системного размера текста. Простая смена других свойств не
  // требует повторной подготовки строк.
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory
      != traitCollection.preferredContentSizeCategory
    {
      setNeedsLayout()
    }
  }
  // Снимаем место чтения до смены размеров. Новая ширина или шрифт отменяют подготовку старых
  // строк и сбрасывают сохранённые кадры сцены. Затем возвращаем позицию и запрашиваем следующий
  // кадр.
  override func layoutSubviews() {
    let nextFont = desiredFontSize
    let changed = lastSize != bounds.size || layoutFontSize != nextFont
    let anchor = changed ? readingAnchor(viewport: lastSize.height) : nil
    super.layoutSubviews()
    if changed {
      let textChanged = lastSize.width != bounds.width || layoutFontSize != nextFont
      lastSize = bounds.size
      layoutFontSize = nextFont
      if textChanged {
        preparedRowWindow = nil
        for token in inFlight.values { token.cancel() }
        inFlight.removeAll()
        scene.advanceGeneration()
        cache.clear()
        pendingAnchor = anchor
      }
      if let anchor { setGeometry(anchor: anchor) }
    }
    layoutPlane()
    schedule()
  }
  // Объединяем запросы к одному обновлению дисплея и включаем его только при необходимости.
  // Частота подстраивается под доступную частоту экрана.
  func schedule() {
    guard !queued, !closed else { return }
    queued = true
    if renderLink == nil {
      let link = CADisplayLink(target: renderTick, selector: #selector(SceneRenderTick.tick(_:)))
      let maximum = Float(
        window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond)
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: min(60, maximum), maximum: maximum, preferred: maximum)
      renderLink = link
      link.add(to: .main, forMode: .common)
    }
    renderLink?.isPaused = false
  }
  // Снимаем отметку ожидания до работы и берём видимое положение инерции на время следующего
  // кадра. Если во время отрисовки ничего не изменилось и инерция закончилась, ставим вызовы
  // дисплея на паузу.
  private func renderScheduledFrame(_ link: CADisplayLink) {
    guard !closed, queued || compositorFlight != nil else {
      link.isPaused = true
      return
    }
    queued = false
    if compositorFlight != nil { sampleCompositorFlight(at: link.targetTimestamp) }
    render()
    // Изменения, поступившие во время согласования, обрабатываются следующим проходом
    if !queued && compositorFlight == nil { link.isPaused = true }
  }
  // Оцениваем, к какому обновлению можно успеть остановить инерцию на слое. При отсутствии
  // недавнего замера даём срок по частоте экрана, чтобы не вернуть вид к уже пройденной точке.
  func compositorCatchTime(at now: TimeInterval) -> TimeInterval {
    guard let link = renderLink, link.timestamp > 0 else {
      let rate = window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
      return now + 2 / Double(max(rate, 60))
    }
    let interval = max(1.0 / 120, min(1.0 / 30, link.targetTimestamp - link.timestamp))
    return min(max(now, link.targetTimestamp), now + interval) + interval
  }
  // Бросаем запас подготовленных строк и уменьшаем допустимую память рисунков. Сообщения остаются
  // в истории и могут быть заново рассчитаны.
  func trimMemory() {
    preparedRowWindow = nil
    cache.limit = 16 * 1024 * 1024
    cache.trim()
  }
  // Завершаем ожидание первого кадра, закрываем просмотр и снимаем проигрыватель. Отменяем
  // запросы, инерцию и подготовку, затем очищаем сцену и элементы доступности. Поздние ответы
  // больше не должны менять экран.
  func close() {
    mediaExport?.cancel()
    mediaExport = nil
    onStudioGenerationAction = nil
    guard !closed else { return }
    closed = true
    finishCompositorFlight(at: viewportOffsetY, settle: false)
    pendingCompositorTrajectory = nil
    preparedRowWindow = nil
    finishInitialFrame(.failure(RepoError.cancelled))
    let gallery = mediaGallery
    mediaGallery = nil
    gallery?.close(animated: false, returnToChat: false)
    studioPreview?.close(animated: false)
    queued = false
    renderLink?.invalidate()
    renderLink = nil
    pendingHeights.removeAll()
    let viewer = photoViewer
    photoViewer = nil
    viewer?.dismiss(animated: false)
    frameProbe.stop()
    motionProbe.close()
    retirePlayerPresentation()
    generation += 1
    pageTask?.cancel()
    metadataTask?.cancel()
    pages?.close()
    for token in inFlight.values { token.cancel() }
    inFlight.removeAll()
    scene.close()
    viewerMedia?.releaseIdleImages()
    days.close()
    cache.clear()
    loaded.removeAll()
    index = HistoryIndex()
    plane.accessibilityElements = nil
    accessibilityEntries.removeAll()
    accessibilityUsed.removeAll()
    onMessageTap = nil
    onMessageLongPress = nil
    onMessageAction = nil
    worker.close()
  }
}
