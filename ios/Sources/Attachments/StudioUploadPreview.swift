import UIKit

@MainActor final class StudioUploadPreview: UIViewController {
  private let surface: InlinePlayerSurface
  private let player: MediaCoordinator
  private let attachment: Attachment
  private var onClose: ((Bool) -> Void)?
  private let canEnhance: Bool
  private let panel = UIView()
  private let scrim = UIButton(type: .custom)
  private let handle = UIView()
  private let hitFrame = UIButton(type: .custom)
  private let remaining = UILabel()
  private let expand = UIButton(type: .system)
  private let collapse = UIButton(type: .system)
  private let enhance = UIButton(type: .system)
  private var expanded = false
  private var closing = false

  init(
    surface: InlinePlayerSurface, player: MediaCoordinator, attachment: Attachment,
    canEnhance: Bool, onClose: @escaping (Bool) -> Void
  ) {
    self.surface = surface
    self.player = player
    self.attachment = attachment
    self.canEnhance = canEnhance
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  override var preferredStatusBarStyle: UIStatusBarStyle { expanded ? .lightContent : .default }

  override func loadView() {
    view = UIView()
    view.accessibilityViewIsModal = true
    scrim.backgroundColor = .clear
    scrim.accessibilityLabel = "Закрыть предпросмотр"
    scrim.accessibilityIdentifier = "studio.upload.dismiss"
    scrim.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    view.addSubview(scrim)

    panel.backgroundColor = KandinskyPalette.studioSheet
    panel.layer.cornerRadius = 28
    panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    let dismissGesture = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
    dismissGesture.direction = .down
    panel.addGestureRecognizer(dismissGesture)
    view.addSubview(panel)
    handle.backgroundColor = KandinskyPalette.studioSheetHandle
    handle.layer.cornerRadius = 2
    panel.addSubview(handle)

    view.addSubview(surface)
    surface.attach()
    hitFrame.isAccessibilityElement = false
    hitFrame.addAction(UIAction { [weak self] _ in self?.setExpanded(true) }, for: .touchUpInside)
    view.addSubview(hitFrame)
    remaining.textColor = .white
    remaining.font = .systemFont(ofSize: 11)
    remaining.textAlignment = .center
    remaining.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    remaining.layer.cornerRadius = 5
    remaining.clipsToBounds = true
    remaining.isAccessibilityElement = true
    remaining.accessibilityIdentifier = "studio.upload.remaining"
    view.addSubview(remaining)
    setup(
      expand, image: "KandinskyExpand", size: 20, tint: KandinskyPalette.studioInk,
      label: "На весь экран", id: "studio.upload.expand", value: true)
    setup(
      collapse, image: "KandinskyUploadClose", size: 20, tint: .white,
      label: "Закрыть просмотр", id: "studio.upload.collapse", value: false)
    if canEnhance {
      enhance.setTitle("Улучшить видео", for: .normal)
      enhance.tintColor = KandinskyPalette.studioInk
      enhance.accessibilityIdentifier = "studio.upload.enhance"
      enhance.addAction(
        UIAction { [weak self] _ in self?.close(enhancing: true) }, for: .touchUpInside)
      view.addSubview(enhance)
    }
    setExpanded(false)
  }

  private func setup(
    _ button: UIButton, image: String, size: CGFloat, tint: UIColor,
    label: String, id: String, value: Bool
  ) {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let icon = renderer.image { _ in
      UIImage(named: image)?.withTintColor(tint, renderingMode: .alwaysOriginal)
        .draw(in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    button.setImage(icon.withRenderingMode(.alwaysOriginal), for: .normal)
    button.accessibilityLabel = label
    button.accessibilityIdentifier = id
    button.addAction(UIAction { [weak self] _ in self?.setExpanded(value) }, for: .touchUpInside)
    view.addSubview(button)
  }

  func update() {
    guard isViewLoaded, !closing, !expanded else { return }
    let duration = player.durationMs > 0 ? player.durationMs : attachment.durationMs ?? 0
    let seconds = max(0, duration - player.positionMs + 999) / 1000
    let value = String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    if remaining.text != value {
      remaining.text = value
      view.setNeedsLayout()
    }
    hitFrame.isUserInteractionEnabled = player.isReady && player.lastError == nil
    expand.isEnabled = hitFrame.isUserInteractionEnabled
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets
    let bounds = view.bounds
    if expanded {
      surface.frame = bounds

      collapse.frame = CGRect(x: 4, y: safe.top, width: 48, height: 48)
      return
    }

    let square = max(1, min(bounds.width - 40, bounds.height - safe.top - safe.bottom - 136))
    let top = bounds.height - safe.bottom - 136 - square
    let left = (bounds.width - square) / 2
    let image = CGRect(x: left, y: top + 68, width: square, height: square)
    scrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, top))
    panel.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    handle.frame = CGRect(x: panel.bounds.midX - 16, y: 22, width: 32, height: 4)
    surface.frame = image
    hitFrame.frame = image
    let badgeWidth = ceil(remaining.intrinsicContentSize.width) + 10
    remaining.frame = CGRect(x: image.minX + 6, y: image.minY + 6, width: badgeWidth, height: 17)
    expand.frame = CGRect(x: image.maxX - 48, y: image.maxY, width: 48, height: 48)
    enhance.frame = CGRect(x: image.minX, y: image.maxY, width: 142, height: 48)
  }

  private func setExpanded(_ value: Bool) {
    if value && !player.isReady { return }
    expanded = value
    view.backgroundColor = value ? .black : UIColor.black.withAlphaComponent(0.54)
    for item in [scrim, panel, hitFrame, remaining, expand, enhance] { item.isHidden = value }
    collapse.isHidden = !value

    surface.studioPreviewBackground = !value
    surface.layer.cornerRadius = value ? 0 : 12
    view.setNeedsLayout()
    setNeedsStatusBarAppearanceUpdate()
    update()
  }

  /// Итоговое освобождение видеовыхода выполняется после закрытия экрана.
  @objc private func swipedDown() { close() }

  override func accessibilityPerformEscape() -> Bool {
    if expanded { setExpanded(false) } else { close() }
    return true
  }

  func close(animated: Bool = true, enhancing: Bool = false) {
    guard !closing else { return }
    closing = true
    let done = onClose
    onClose = nil
    dismiss(animated: animated) { [surface] in
      surface.detach()
      surface.removeFromSuperview()
      surface.studioPreviewBackground = false

      surface.layer.cornerRadius = 12

      done?(enhancing)
    }
  }
}
