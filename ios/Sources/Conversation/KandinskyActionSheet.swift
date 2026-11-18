// Показывает команды выбранной строки на прокручиваемой панели айфона. Выбранное действие
// начинается после того, как панель уйдёт с экрана.

import UIKit

struct KandinskySheetAction {
  let title: String, symbol: String
  var destructive = false
  let action: @MainActor () -> Void
}

@MainActor final class KandinskyActionSheet: UIViewController {
  private let heading: String?
  private let items: [KandinskySheetAction]
  private let panel = NativeGlassPanel(frame: .zero)
  private let stack = UIStackView()
  private let scroll = UIScrollView()
  // Принимает заголовок и команды, задаёт особый вид показа поверх текущего экрана. Предыдущее
  // окно остаётся под панелью.
  init(title: String? = nil, items: [KandinskySheetAction]) {
    heading = title
    self.items = items
    super.init(nibName: nil, bundle: nil)
    overrideUserInterfaceStyle = .light
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }
  // Запрещает создание без переданного списка действий. Загрузка только разметки оставила бы
  // панель без рабочих команд.
  required init?(coder: NSCoder) { fatalError() }
  // Собирает кнопки, отмену и фон, переводит доступность на панель. Любое действие начинается
  // после закрытия, чтобы следующая панель не наложилась на первую.
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
    view.accessibilityViewIsModal = true
    let outside = UIButton()
    outside.addAction(
      UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
    outside.isAccessibilityElement = false
    outside.frame = view.bounds
    outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(outside)
    panel.radius = 24
    panel.isUserInteractionEnabled = true
    view.addSubview(panel)
    stack.axis = .vertical
    stack.spacing = 0
    view.addSubview(scroll)
    scroll.addSubview(stack)
    if let heading {
      let label = UILabel()
      label.text = heading
      label.font = .preferredFont(forTextStyle: .headline)
      label.textColor = .black
      label.adjustsFontForContentSizeCategory = true
      label.numberOfLines = 0
      label.textAlignment = .center
      label.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
      stack.addArrangedSubview(label)
    }
    for (index, item)
      in (items + [KandinskySheetAction(title: "Отмена", symbol: "xmark", action: {})]).enumerated()
    {
      var config = UIButton.Configuration.plain()
      config.title = item.title
      config.image = UIImage(systemName: item.symbol)
      config.imagePadding = 14
      config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
      config.baseForegroundColor = item.destructive ? .systemRed : .black
      let button = KandinskySheetButton(configuration: config)
      button.contentHorizontalAlignment = .leading
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      button.accessibilityIdentifier = "actions.\(index)"
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
      button.addAction(
        UIAction { [weak self] _ in self?.dismiss(animated: true, completion: item.action) },
        for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    UIAccessibility.post(notification: .screenChanged, argument: stack.arrangedSubviews.first)
  }
  // Ограничивает ширину и высоту доступным местом и даёт прокрутке полный размер списка команд.
  // Длинный список не обрежется у края экрана.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let width = min(360, view.bounds.width - 24)
    let contentHeight = stack.systemLayoutSizeFitting(
      CGSize(width: width - 8, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let height = min(view.bounds.height - view.safeAreaInsets.top - 32, contentHeight + 12)
    panel.frame = CGRect(
      x: (view.bounds.width - width) / 2,
      y: view.bounds.height - view.safeAreaInsets.bottom - height - 12, width: width, height: height
    )
    scroll.frame = panel.frame.insetBy(dx: 4, dy: 6)
    stack.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: contentHeight)
    scroll.contentSize = stack.bounds.size
  }
  // Закрывает панель системным жестом доступности, не исполняя ни одной команды.
  override func accessibilityPerformEscape() -> Bool {
    dismiss(animated: true)
    return true
  }
}

private final class KandinskySheetButton: UIButton {
  // Выделяет отдельные места под значок и текст кнопки. При изменении ширины подпись не наложится
  // на изображение.
  override func layoutSubviews() {
    super.layoutSubviews()
    imageView?.contentMode = .scaleAspectFit
    imageView?.frame = CGRect(x: 18, y: (bounds.height - 22) / 2, width: 22, height: 22)
    titleLabel?.frame = CGRect(x: 56, y: 0, width: max(0, bounds.width - 72), height: bounds.height)
  }
}
