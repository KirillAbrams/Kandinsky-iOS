import UIKit

@MainActor final class StudioGenerationSheet: UIViewController {
  private static let mint = UIColor(red: 56 / 255, green: 227 / 255, blue: 178 / 255, alpha: 1)
  private static let listText = UIColor(red: 23 / 255, green: 29 / 255, blue: 26 / 255, alpha: 1)
  private static let attachmentDivider = UIColor(
    red: 191 / 255, green: 201 / 255, blue: 195 / 255, alpha: 1)
  private static let detailDivider = UIColor(
    red: 232 / 255, green: 235 / 255, blue: 231 / 255, alpha: 1)

  private let panel = UIView()
  private let scrim = UIButton(type: .custom)
  private let grip = UIView()
  private let handle = UIView()
  private let stack = UIStackView()
  private let scroll = UIScrollView()
  private var sidePadding: CGFloat = 20
  private var bottomPadding: CGFloat = 16
  private var scrollControlled = false
  private var keyboardInset: CGFloat = 0
  private var lastBottomInset: CGFloat = 0
  private var stackWidth: NSLayoutConstraint!
  private var chipRows: [StudioOptionRow] = []
  private var options: KandinskyOptions
  private weak var dimensionRow: StudioOptionRow?
  private let details = UIStackView()
  private let negative = StudioSettingsField(kind: .negative)
  private let seed = StudioSettingsField(kind: .seed)
  private let error = UILabel()

  init(options: KandinskyOptions) {
    self.options = options
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalPresentationCapturesStatusBarAppearance = true
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  /// Наблюдает за клавиатурой, чтобы доступная область настроек менялась вместе с вводом.
  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityViewIsModal = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(keyboardChanged(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    scrim.backgroundColor = UIColor.black.withAlphaComponent(0.54)
    scrim.accessibilityLabel = "Закрыть панель"
    scrim.accessibilityIdentifier = "studio.panel.dismiss"
    scrim.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
    view.addSubview(scrim)
    panel.backgroundColor = .white
    panel.layer.cornerRadius = 28
    panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    panel.clipsToBounds = true
    panel.tintColor = KandinskyPalette.studioInk
    view.addSubview(panel)
    panel.addSubview(grip)
    grip.addSubview(handle)
    handle.backgroundColor = KandinskyPalette.studioSheetHandle
    handle.layer.cornerRadius = 2
    let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
    swipe.direction = .down
    grip.addGestureRecognizer(swipe)

    scroll.keyboardDismissMode = .interactive
    scroll.accessibilityIdentifier = "studio.panel.content"
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.showsVerticalScrollIndicator = false
    panel.addSubview(scroll)
    stack.axis = .vertical
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    stackWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
    NSLayoutConstraint.activate([
      scroll.contentLayoutGuide.widthAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.widthAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.centerXAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerXAnchor),
      stackWidth
    ])
  }

  /// При появлении клавиатуры прокручивает к редактируемому полю, чтобы введённый текст оставался виден.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let bounds = view.bounds
    let safe = view.safeAreaInsets
    let bodyWidth = min(bounds.width, 640) - sidePadding * 2
    guard bodyWidth > 0 else { return }
    if stackWidth.constant != -sidePadding * 2 { stackWidth.constant = -sidePadding * 2 }
    for row in chipRows { row.updateHeight(width: bodyWidth) }
    if details.superview != nil && negative.superview != nil {
      negative.updateHeight(width: bodyWidth)
    }
    let contentHeight = stack.systemLayoutSizeFitting(
      CGSize(width: bodyWidth, height: 0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let inset = max(safe.bottom, keyboardInset)
    let maximumHeight = scrollControlled ? bounds.height : bounds.height * 9 / 16
    let available = max(0, maximumHeight - 48 - inset)
    let height = min(
      contentHeight + bottomPadding, available,
      scrollControlled ? bounds.height * 0.85 + bottomPadding : available)
    let panelWidth = bodyWidth + sidePadding * 2
    let panelHeight = height + 48 + inset
    scrim.frame = bounds
    panel.frame = CGRect(
      x: (bounds.width - panelWidth) / 2, y: bounds.height - panelHeight,
      width: panelWidth, height: panelHeight)
    grip.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 48)
    handle.frame = CGRect(x: (panelWidth - 32) / 2, y: 22, width: 32, height: 4)
    scroll.frame = CGRect(x: 0, y: 48, width: panelWidth, height: height)
    if scroll.contentInset.bottom != bottomPadding { scroll.contentInset.bottom = bottomPadding }
    let keyboardMoved = inset != lastBottomInset
    lastBottomInset = inset
    if keyboardMoved, inset > safe.bottom,
      let field = [negative, seed].first(where: { $0.isEditing })
    {
      scroll.layoutIfNeeded()
      let fieldFrame = field.convert(field.bounds, to: scroll).insetBy(dx: 0, dy: -8)
      scroll.scrollRectToVisible(fieldFrame, animated: false)
    }
  }

  @objc private func keyboardChanged(_ notification: Notification) {
    guard let window = view.window,
      let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }
    let local = view.convert(frame, from: window.screen.coordinateSpace)
    keyboardInset = max(0, view.bounds.maxY - local.minY)
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }

  override func accessibilityPerformEscape() -> Bool {
    close()
    return true
  }

  @objc private func swipedDown() { close() }

  /// При наличии продолжения вызывает его после закрытия представления.
  private func close(completion: (() -> Void)? = nil) {
    dismiss(animated: true, completion: completion)
  }

  func showModels(_ models: [StudioModel], onSelect: @escaping (StudioModel) -> Void) {
    loadViewIfNeeded()
    sidePadding = 12
    bottomPadding = 24
    let title = label("Выберите модель", size: 23, weight: .semibold)
    title.attributedText = NSAttributedString(
      string: "Выберите модель",
      attributes: [
        .font: title.font as Any, .kern: -0.6, .foregroundColor: KandinskyPalette.studioInk
      ])
    let header = UIStackView(arrangedSubviews: [title])
    header.layoutMargins = .init(top: 16, left: 16, bottom: 16, right: 16)
    header.isLayoutMarginsRelativeArrangement = true
    title.heightAnchor.constraint(greaterThanOrEqualToConstant: 33).isActive = true
    stack.addArrangedSubview(header)
    if models.isEmpty {
      let empty = UIStackView(arrangedSubviews: [label("Не удалось загрузить модели", size: 15)])
      empty.layoutMargins = .init(top: 16, left: 16, bottom: 16, right: 16)
      empty.isLayoutMarginsRelativeArrangement = true
      stack.addArrangedSubview(empty)
    }
    for model in models {
      addTile(
        title: model.name, subtitle: model.description,
        icon: model.id == "image" ? "KandinskyAttachmentPhoto" : "KandinskyModelVideo",
        selected: model.id == options.model
      ) { onSelect(model) }
    }
  }

  func showAttachments(onSelect: @escaping (AttachmentSource) -> Void) {
    loadViewIfNeeded()
    sidePadding = 0
    bottomPadding = 0
    panel.backgroundColor = KandinskyPalette.studioSheet
    addTile(
      title: "Оживить фото из галереи", subtitle: "Видео из фотографии",
      icon: "KandinskyAttachmentPhoto"
    ) { onSelect(.photo) }
    addTile(title: "Снять фото", subtitle: "", icon: "KandinskyAttachmentCamera") {
      onSelect(.camera)
    }
    addTile(
      title: "Загрузить и посмотреть видео", subtitle: "MP4 до 20 МБ и 60 секунд",
      icon: "KandinskyModelVideo"
    ) { onSelect(.video) }
  }

  func appendRecentUploads(_ uploads: [StudioUpload], onSelect: @escaping (StudioUpload) -> Void) {
    guard !uploads.isEmpty, presentingViewController != nil else { return }
    let divider = UIView()
    let rule = UIView()
    rule.backgroundColor = Self.attachmentDivider
    rule.translatesAutoresizingMaskIntoConstraints = false
    divider.addSubview(rule)
    NSLayoutConstraint.activate([
      divider.heightAnchor.constraint(equalToConstant: 16),
      rule.heightAnchor.constraint(equalToConstant: 1),
      rule.centerYAnchor.constraint(equalTo: divider.centerYAnchor),
      rule.leadingAnchor.constraint(equalTo: divider.leadingAnchor),
      rule.trailingAnchor.constraint(equalTo: divider.trailingAnchor)
    ])
    stack.addArrangedSubview(divider)
    let heading = label("Недавние загрузки", size: 15)
    heading.textColor = KandinskyPalette.studioMuted
    heading.textAlignment = .center
    heading.heightAnchor.constraint(equalToConstant: 46).isActive = true
    stack.addArrangedSubview(heading)
    for upload in uploads.prefix(5) {
      addTile(
        title: upload.title, subtitle: "",
        icon: upload.isVideo ? "KandinskyRecentVideo" : "KandinskyAttachmentPhoto",
        id: "studio.recent." + upload.blobId
      ) { onSelect(upload) }
    }
    view.setNeedsLayout()
  }

  private func addTile(
    title: String, subtitle: String, icon: String, id: String? = nil,
    selected: Bool = false, onSelect: @escaping () -> Void
  ) {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = title
    button.accessibilityHint = subtitle.isEmpty ? nil : subtitle
    button.accessibilityIdentifier = id
    if selected { button.accessibilityTraits.insert(.selected) }
    let leading = UIImageView(image: UIImage(named: icon)?.withRenderingMode(.alwaysTemplate))
    leading.tintColor = KandinskyPalette.studioSheetHandle
    leading.contentMode = .scaleAspectFit
    let titleLabel = label(title, size: 16)
    titleLabel.textColor = Self.listText
    titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    let captions = UIStackView(arrangedSubviews: [titleLabel])
    captions.axis = .vertical
    if !subtitle.isEmpty {
      let secondary = label(subtitle, size: 14)
      secondary.textColor = KandinskyPalette.studioSheetHandle
      secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
      captions.addArrangedSubview(secondary)
    }
    for item in [leading, captions] {
      item.translatesAutoresizingMaskIntoConstraints = false
      item.isUserInteractionEnabled = false
      item.isAccessibilityElement = false
      button.addSubview(item)
    }
    var endPadding: CGFloat = 24
    if selected {
      let check = UIImageView(
        image: UIImage(named: "KandinskyModelCheck")?.withRenderingMode(.alwaysTemplate))
      check.tintColor = Self.mint
      check.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(check)
      NSLayoutConstraint.activate([
        check.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -24),
        check.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        check.widthAnchor.constraint(equalToConstant: 24),
        check.heightAnchor.constraint(equalToConstant: 24)
      ])
      endPadding += 40
    }
    NSLayoutConstraint.activate([
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle.isEmpty ? 56 : 72),
      leading.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
      leading.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      leading.widthAnchor.constraint(equalToConstant: 24),
      leading.heightAnchor.constraint(equalToConstant: 24),
      captions.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 56),
      captions.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -endPadding),
      captions.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      captions.topAnchor.constraint(greaterThanOrEqualTo: button.topAnchor, constant: 8),
      captions.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor, constant: -8)
    ])
    button.addAction(
      UIAction { [weak self] _ in self?.close(completion: onSelect) }, for: .touchUpInside)
    stack.addArrangedSubview(button)
  }

  func showSettings(
    _ available: StudioCapabilities, onCountChange: @escaping (Int) -> Void,
    onApply: @escaping (KandinskyOptions) -> Void
  ) {
    loadViewIfNeeded()
    scrollControlled = true
    options.quality = available.quality.first { $0.id == options.quality }?.id ?? "standard"
    options.resolution =
      available.resolutions.first { $0.id == options.resolution }?.id ?? "standard"
    if !available.aspects.contains(options.aspect), let first = available.aspects.first {
      options.aspect = first
    }
    if !available.duration_seconds.contains(options.duration_seconds) {
      options.duration_seconds = available.duration_seconds.last ?? 5
    }
    options.count = min(max(options.count ?? 1, 1), available.max_count)
    let title = label("Параметры", size: 24, weight: .semibold)
    title.heightAnchor.constraint(greaterThanOrEqualToConstant: 35).isActive = true
    stack.addArrangedSubview(title)
    stack.setCustomSpacing(20, after: title)
    section(
      "Качество", choices: available.quality.map { ($0.id, $0.name) },
      selected: options.quality
    ) { [weak self] in self?.options.quality = $0 }
    section(
      "Формат", choices: available.aspects.map { ($0, $0) },
      selected: options.aspect
    ) { [weak self] aspect in
      guard let self else { return }
      self.options.aspect = aspect
      self.updateDimensions(available.resolutions)
    }
    let size = section(
      "Размер", choices: available.resolutions.map { ($0.id, $0.label(aspect: options.aspect)) },
      selected: options.resolution
    ) { [weak self] in self?.options.resolution = $0 }
    dimensionRow = size
    if !available.duration_seconds.isEmpty {
      section(
        "Длительность", choices: available.duration_seconds.map { (String($0), "\($0) с") },
        selected: String(options.duration_seconds)
      ) { [weak self] in
        self?.options.duration_seconds = Int($0) ?? 5
      }
    }
    section(
      "Количество", choices: (1...max(1, available.max_count)).map { (String($0), String($0)) },
      selected: options.count.map(String.init), spacingAfter: 0
    ) { [weak self] value in
      guard let count = Int(value), let self else { return }
      self.options.count = count
      onCountChange(count)
    }
    addDetails(available)
    error.numberOfLines = 0
    error.textColor = .systemRed
    error.font = .systemFont(ofSize: 14)
    error.isHidden = true
    stack.addArrangedSubview(error)
    let done = UIButton(type: .system)
    done.setTitle("Готово", for: .normal)
    done.setTitleColor(.white, for: .normal)
    done.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
    done.backgroundColor = KandinskyPalette.studioInk
    done.layer.cornerRadius = 14
    done.heightAnchor.constraint(equalToConstant: 52).isActive = true
    done.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        let rawSeed = self.seed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Int(rawSeed)
        if !rawSeed.isEmpty && !(number.map { (0...2147483647).contains($0) } ?? false) {
          self.error.text = "Seed: число от 0 до 2147483647"
          self.error.isHidden = false
          self.view.setNeedsLayout()
          return
        }
        self.options.seed = number
        self.options.negative_prompt =
          available.negative_prompt
          ? self.negative.text.trimmingCharacters(in: .whitespacesAndNewlines)
          : nil
        if available.guidance == nil { self.options.guidance_scale = nil }
        onApply(self.options)
        self.close()
      }, for: .touchUpInside)
    stack.addArrangedSubview(done)
  }

  /// Возвращает созданные элементы, чтобы зависимые подписи можно было обновить при смене пропорций.
  @discardableResult private func section(
    _ title: String, choices: [(String, String)], selected: String?, spacingAfter: CGFloat = 14,
    change: @escaping (String) -> Void
  ) -> StudioOptionRow {
    let titleView = label(title, size: 15)
    titleView.heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
    stack.addArrangedSubview(titleView)
    let row = StudioOptionRow()
    for (id, name) in choices {
      let button = StudioOptionButton(title: name, selected: selected == id)
      button.accessibilityIdentifier = "studio.option.\(title).\(id)"
      button.addAction(
        UIAction { [weak self, weak row, weak button] _ in
          guard let self, let row else { return }
          for item in row.buttons { item.setSelected(item === button) }
          change(id)
          self.view.setNeedsLayout()
        }, for: .touchUpInside)
      row.add(button)
    }
    chipRows.append(row)
    stack.addArrangedSubview(row)
    stack.setCustomSpacing(spacingAfter, after: row)
    return row
  }

  private func updateDimensions(_ sizes: [StudioChoice]) {
    guard let row = dimensionRow else { return }
    for (size, button) in zip(sizes, row.buttons) {
      button.updateTitle(size.label(aspect: options.aspect))
    }
  }

  private func addDetails(_ available: StudioCapabilities) {
    details.axis = .vertical
    let upperRule = UIView()
    let lowerRule = UIView()
    for rule in [upperRule, lowerRule] {
      rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    let toggle = UIButton(type: .system)
    toggle.setTitle("Дополнительно", for: .normal)
    toggle.titleLabel?.font = .systemFont(ofSize: 16)
    toggle.contentHorizontalAlignment = .leading
    toggle.heightAnchor.constraint(equalToConstant: 56).isActive = true
    let arrow = UIImageView(image: StudioOptionButton.chevron)
    arrow.tintColor = KandinskyPalette.studioSheetHandle
    arrow.translatesAutoresizingMaskIntoConstraints = false
    toggle.addSubview(arrow)
    NSLayoutConstraint.activate([
      arrow.trailingAnchor.constraint(equalTo: toggle.trailingAnchor),
      arrow.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
      arrow.widthAnchor.constraint(equalToConstant: 24),
      arrow.heightAnchor.constraint(equalToConstant: 24)
    ])
    toggle.addAction(
      UIAction { [weak self, weak arrow, weak upperRule, weak lowerRule] _ in
        guard let self, let lowerRule,
          let index = self.stack.arrangedSubviews.firstIndex(of: lowerRule)
        else { return }
        let expanded = self.details.superview == nil
        if expanded {
          self.stack.insertArrangedSubview(self.details, at: index)
        } else {
          self.details.endEditing(true)
          self.stack.removeArrangedSubview(self.details)
          self.details.removeFromSuperview()
        }
        arrow?.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        arrow?.tintColor =
          expanded ? KandinskyPalette.studioInk : KandinskyPalette.studioSheetHandle
        upperRule?.backgroundColor = expanded ? Self.detailDivider : .clear
        lowerRule.backgroundColor = upperRule?.backgroundColor
        self.view.setNeedsLayout()
      }, for: .touchUpInside)
    for item in [upperRule, toggle, lowerRule] { stack.addArrangedSubview(item) }
    stack.setCustomSpacing(8, after: lowerRule)

    if available.negative_prompt {
      negative.text = options.negative_prompt ?? ""
      negative.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
      details.addArrangedSubview(negative)
    }
    seed.text = options.seed.map(String.init) ?? ""
    details.addArrangedSubview(seed)
    if let guidance = available.guidance {
      let value = options.guidance_scale ?? guidance.default
      let title = label(guidanceLabel(value), size: 15)
      title.textAlignment = .center
      title.heightAnchor.constraint(equalToConstant: 22).isActive = true
      let slider = StudioGuidanceSlider(minimum: guidance.min, maximum: guidance.max, value: value)
      slider.addAction(
        UIAction { [weak self, weak slider, weak title] _ in
          guard let self, let slider else { return }
          self.options.guidance_scale = slider.value
          title?.text = self.guidanceLabel(slider.value)
        }, for: .valueChanged)
      details.setCustomSpacing(12, after: seed)
      details.addArrangedSubview(title)
      details.addArrangedSubview(slider)
    }
  }

  private func guidanceLabel(_ value: Double) -> String {
    "Следование описанию " + String(format: "%.1f", value)
  }

  private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> UILabel {
    let result = UILabel()
    result.text = text
    result.textColor = KandinskyPalette.studioInk
    result.font = .systemFont(ofSize: size, weight: weight)
    result.numberOfLines = 0
    return result
  }
}

@MainActor private final class StudioSettingsField: UIView, UITextViewDelegate {
  enum Kind { case seed, negative }
  private let kind: Kind
  private let plate = UIView()
  private let caption = UILabel()
  private let counter = UILabel()
  private let seedEditor = UITextField()
  private let promptEditor = UITextView()
  private var fieldHeight: NSLayoutConstraint!
  private var editorHeight: CGFloat = 24
  var onHeightChange: (() -> Void)?

  var text: String {
    get { kind == .seed ? seedEditor.text ?? "" : promptEditor.text }
    set {
      if kind == .seed { seedEditor.text = newValue } else { promptEditor.text = newValue }
      refresh()
    }
  }

  var isEditing: Bool { seedEditor.isFirstResponder || promptEditor.isFirstResponder }
  private var floating: Bool { isEditing || !text.isEmpty }

  init(kind: Kind) {
    self.kind = kind
    super.init(frame: .zero)
    let title = kind == .seed ? "Seed" : "Что исключить"
    plate.backgroundColor = KandinskyPalette.studioSurface
    plate.layer.cornerRadius = 14
    plate.clipsToBounds = true
    addSubview(plate)
    caption.text = title
    caption.isAccessibilityElement = false
    caption.isUserInteractionEnabled = false
    fieldHeight = heightAnchor.constraint(equalToConstant: kind == .seed ? 60 : 80)
    fieldHeight.isActive = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(focus))
    tap.cancelsTouchesInView = false
    plate.addGestureRecognizer(tap)

    if kind == .seed {
      seedEditor.keyboardType = .numberPad
      seedEditor.font = .systemFont(ofSize: 16)
      seedEditor.textColor = KandinskyPalette.studioInk
      seedEditor.accessibilityLabel = title
      seedEditor.accessibilityIdentifier = "studio.settings.seed"
      for event: UIControl.Event in [.editingDidBegin, .editingChanged, .editingDidEnd] {
        seedEditor.addAction(UIAction { [weak self] _ in self?.refresh() }, for: event)
      }
      plate.addSubview(seedEditor)
    } else {
      promptEditor.delegate = self
      promptEditor.backgroundColor = .clear
      promptEditor.font = .systemFont(ofSize: 16)
      promptEditor.textColor = KandinskyPalette.studioInk
      promptEditor.textContainerInset = .zero
      promptEditor.textContainer.lineFragmentPadding = 0
      promptEditor.accessibilityLabel = title
      promptEditor.accessibilityIdentifier = "studio.settings.negative"
      plate.addSubview(promptEditor)
      counter.font = .systemFont(ofSize: 12)
      counter.textAlignment = .right
      counter.textColor = KandinskyPalette.studioSheetHandle
      counter.accessibilityIdentifier = "studio.settings.negative.count"
      addSubview(counter)
    }
    plate.addSubview(caption)
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  func updateHeight(width: CGFloat) {
    guard kind == .negative else { return }
    let fit = promptEditor.sizeThatFits(
      CGSize(width: max(1, width - 44), height: .greatestFiniteMagnitude)
    ).height
    let lines = max(1, Int((fit / (promptEditor.font?.lineHeight ?? 19)).rounded()))
    editorHeight = CGFloat(min(3, lines)) * 24
    let height = 56 + editorHeight
    if fieldHeight.constant != height { fieldHeight.constant = height }
    let scroll = lines > 3
    if promptEditor.isScrollEnabled != scroll { promptEditor.isScrollEnabled = scroll }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let plateHeight = bounds.height - (kind == .negative ? 20 : 0)
    plate.frame = CGRect(x: 0, y: 0, width: bounds.width, height: plateHeight)
    let width = max(0, bounds.width - 44)
    caption.frame = CGRect(
      x: 22, y: floating ? 7 : (plateHeight - 24) / 2,
      width: width, height: floating ? 16 : 24)
    let inputFrame = CGRect(x: 22, y: floating ? 26 : 18, width: width, height: editorHeight)
    if kind == .seed {
      seedEditor.frame = inputFrame
    } else {
      promptEditor.frame = inputFrame
      counter.frame = CGRect(x: 22, y: plateHeight + 4, width: width, height: 16)
    }
  }

  @objc private func focus() {
    if kind == .seed {
      seedEditor.becomeFirstResponder()
    } else {
      promptEditor.becomeFirstResponder()
    }
  }

  func textViewDidBeginEditing(_ textView: UITextView) { refresh() }
  func textViewDidEndEditing(_ textView: UITextView) { refresh() }

  func textViewDidChange(_ textView: UITextView) {
    if textView.markedTextRange == nil && textView.text.count > 2000 {
      let selection = textView.selectedRange.location
      textView.text = String(textView.text.prefix(2000))
      textView.selectedRange = NSRange(
        location: min(selection, textView.text.utf16.count), length: 0)
    }
    refresh()
  }

  private func refresh() {
    caption.font = .systemFont(ofSize: floating ? 12 : 16)
    caption.textColor = isEditing ? KandinskyPalette.studioInk : KandinskyPalette.studioSheetHandle
    if kind == .seed {
      seedEditor.placeholder = isEditing ? "Случайный" : nil
    } else {
      counter.text = "\(text.count)/2000"
      onHeightChange?()
    }
    setNeedsLayout()
  }
}

@MainActor private final class StudioGuidanceSlider: UIControl {
  private static let steps = 14
  private let minimum: Double
  private let step: Double
  private var selectedStep: Int
  var value: Double { minimum + Double(selectedStep) * step }

  init(minimum: Double, maximum: Double, value: Double) {
    self.minimum = minimum
    step = (maximum - minimum) / Double(Self.steps)
    selectedStep = step > 0 ? max(0, min(Self.steps, Int(((value - minimum) / step).rounded()))) : 0
    super.init(frame: .zero)
    heightAnchor.constraint(equalToConstant: 48).isActive = true
    isOpaque = false
    isAccessibilityElement = true
    accessibilityTraits = .adjustable
    accessibilityLabel = "Следование описанию"
    accessibilityIdentifier = "studio.settings.guidance"
    updateValueDescription()
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  override func draw(_ rect: CGRect) {
    let length = max(0, bounds.width - 52)
    guard length > 0 else { return }
    let y = bounds.midY
    let x = 26 + length * CGFloat(selectedStep) / CGFloat(Self.steps)
    let mint = UIColor(red: 56 / 255, green: 227 / 255, blue: 178 / 255, alpha: 1)
    UIColor(red: 222 / 255, green: 228 / 255, blue: 223 / 255, alpha: 1).setFill()
    UIBezierPath(
      roundedRect: CGRect(x: 24, y: y - 2, width: length + 4, height: 4), cornerRadius: 2
    ).fill()
    mint.setFill()
    UIBezierPath(roundedRect: CGRect(x: 24, y: y - 3, width: x - 24, height: 6), cornerRadius: 3)
      .fill()
    for index in 0...Self.steps {
      let tick = 26 + length * CGFloat(index) / CGFloat(Self.steps)
      (index <= selectedStep
        ? UIColor(red: 132 / 255, green: 238 / 255, blue: 207 / 255, alpha: 1) : mint).setFill()
      UIBezierPath(ovalIn: CGRect(x: tick - 1, y: y - 1, width: 2, height: 2)).fill()
    }
    mint.setFill()
    UIColor.black.setStroke()
    let thumb = UIBezierPath(ovalIn: CGRect(x: x - 10.5, y: y - 10.5, width: 21, height: 21))
    thumb.lineWidth = 1
    thumb.fill()
    thumb.stroke()
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    update(with: touch)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    update(with: touch)
    return true
  }

  override func accessibilityIncrement() { select(selectedStep + 1) }
  override func accessibilityDecrement() { select(selectedStep - 1) }

  private func update(with touch: UITouch) {
    let fraction = (touch.location(in: self).x - 26) / max(1, bounds.width - 52)
    select(Int((fraction * CGFloat(Self.steps)).rounded()))
  }

  private func select(_ index: Int) {
    let next = max(0, min(Self.steps, index))
    guard next != selectedStep else { return }
    selectedStep = next
    updateValueDescription()
    setNeedsDisplay()
    sendActions(for: .valueChanged)
  }

  private func updateValueDescription() {
    accessibilityValue = String(format: "%.1f", value)
  }
}

@MainActor private final class StudioOptionRow: UIView {
  private(set) var buttons: [StudioOptionButton] = []
  private var rowHeight: NSLayoutConstraint?

  func add(_ button: StudioOptionButton) {
    buttons.append(button)
    addSubview(button)
  }

  func updateHeight(width: CGFloat) {
    let height = frames(width: width).last?.maxY ?? 0
    if let rowHeight {
      if rowHeight.constant != height { rowHeight.constant = height }
    } else {
      let constraint = heightAnchor.constraint(equalToConstant: height)
      constraint.isActive = true
      rowHeight = constraint
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for (button, frame) in zip(buttons, frames(width: bounds.width)) { button.frame = frame }
  }

  private func frames(width: CGFloat) -> [CGRect] {
    var x: CGFloat = 0
    var y: CGFloat = 0
    return buttons.map { button in
      let itemWidth = min(width, button.fittedWidth)
      if x > 0 && x + itemWidth > width {
        x = 0
        y += 48
      }
      let frame = CGRect(x: x, y: y, width: itemWidth, height: 48)
      x += itemWidth + 8
      return frame
    }
  }
}

@MainActor private final class StudioOptionButton: UIButton {
  private static let font = UIFont.systemFont(ofSize: 14, weight: .medium)
  private static let fill = UIColor(red: 206 / 255, green: 233 / 255, blue: 219 / 255, alpha: 1)
  private static let ink = UIColor(red: 52 / 255, green: 76 / 255, blue: 66 / 255, alpha: 1)
  private static let outline = UIColor(red: 191 / 255, green: 201 / 255, blue: 195 / 255, alpha: 1)
  private static let check = glyph(
    size: 18, points: [(2.7, 8.1), (7.2, 12.6), (15.3, 4.5)], lineWidth: 1.5)
  static let chevron = glyph(size: 24, points: [(7, 10), (12, 15), (17, 10)], lineWidth: 2)

  private let pill = UIView()
  private let caption = UILabel()
  private let icon = UIImageView(image: StudioOptionButton.check)

  init(title: String, selected: Bool) {
    super.init(frame: .zero)
    accessibilityTraits = .button
    pill.layer.cornerRadius = 8
    caption.font = Self.font
    caption.lineBreakMode = .byTruncatingTail
    for child in [pill, caption, icon] {
      child.isUserInteractionEnabled = false
      child.isAccessibilityElement = false
      addSubview(child)
    }
    updateTitle(title)
    setSelected(selected)
  }

  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  private var labelAndPaddingWidth: CGFloat {
    ceil(caption.intrinsicContentSize.width * 3) / 3 + (isSelected ? 54 : 34)
  }

  var fittedWidth: CGFloat { max(48, labelAndPaddingWidth) }

  func updateTitle(_ value: String) {
    accessibilityLabel = value
    caption.attributedText = NSAttributedString(
      string: value, attributes: [.font: Self.font, .kern: 0.1])
    setNeedsLayout()
  }

  /// Запрашивает размещение, поскольку выбранная кнопка дополнительно содержит значок.
  func setSelected(_ selected: Bool) {
    isSelected = selected
    pill.backgroundColor = selected ? Self.fill : .white
    pill.layer.borderColor = Self.outline.cgColor
    pill.layer.borderWidth = selected ? 0 : 1
    caption.textColor = selected ? Self.ink : KandinskyPalette.studioSheetHandle
    icon.isHidden = !selected
    icon.tintColor = Self.ink
    if selected {
      accessibilityTraits.insert(.selected)
    } else {
      accessibilityTraits.remove(.selected)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset = max(0, (bounds.width - labelAndPaddingWidth) / 2)
    pill.frame = bounds.insetBy(dx: inset, dy: 5)
    icon.frame = CGRect(x: inset + 13, y: 15, width: 18, height: 18)
    let start: CGFloat = inset + (isSelected ? 37 : 17)
    caption.frame = CGRect(
      x: start, y: 14, width: max(0, bounds.width - start - inset - 17), height: 20)
  }

  private static func glyph(size: CGFloat, points: [(CGFloat, CGFloat)], lineWidth: CGFloat)
    -> UIImage
  {
    UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
      let line = UIBezierPath()
      line.lineWidth = lineWidth
      line.move(to: CGPoint(x: points[0].0, y: points[0].1))
      for (x, y) in points.dropFirst() { line.addLine(to: CGPoint(x: x, y: y)) }
      context.cgContext.setStrokeColor(UIColor.black.cgColor)
      line.stroke()
    }.withRenderingMode(.alwaysTemplate)
  }
}
