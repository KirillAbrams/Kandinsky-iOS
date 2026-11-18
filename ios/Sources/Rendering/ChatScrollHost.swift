import UIKit
@MainActor private final class SceneRenderTick: NSObject {
  let action: (CADisplayLink) -> Void
  init(action: @escaping (CADisplayLink) -> Void) { self.action = action }
  @objc func tick(_ link: CADisplayLink) { action(link) }
}
@MainActor final class ChatScrollHost: UIScrollView {
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
  private var desiredFontSize: Int {
    Int(UIFontMetrics.default.scaledValue(for: 18, compatibleWith: traitCollection).rounded())
  }
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
  var messageCount: Int { index.rows.count }
  var metrics: SceneMetrics { scene.metrics }
  var loadedCount: Int { pages?.loadedCount ?? loaded.count }
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
  deinit {
    renderLink?.invalidate()
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    worker.close()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory
      != traitCollection.preferredContentSizeCategory
    {
      setNeedsLayout()
    }
  }
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
  /// Сбрасывает признак ожидания до работы, чтобы новые события могли назначить следующий проход.
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
  func compositorCatchTime(at now: TimeInterval) -> TimeInterval {
    guard let link = renderLink, link.timestamp > 0 else {
      let rate = window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
      return now + 2 / Double(max(rate, 60))
    }
    let interval = max(1.0 / 120, min(1.0 / 30, link.targetTimestamp - link.timestamp))
    return min(max(now, link.targetTimestamp), now + interval) + interval
  }
  /// Сами сообщения остаются в истории и могут быть подготовлены снова при необходимости.
  func trimMemory() {
    preparedRowWindow = nil
    cache.limit = 16 * 1024 * 1024
    cache.trim()
  }
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
