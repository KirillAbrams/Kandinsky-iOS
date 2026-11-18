// Представляет строку чата в списке айфона. Разделяет нажатия на название и действия, показывает
// закрепление, выделение и генерацию.

import UIKit

final class StudioThreadCell: UITableViewCell {
  let openButton = UIButton(type: .system)
  let actions = UIButton(type: .system)
  private let highlight = UIView()
  private let marker = UIImageView()
  private let busy = UIActivityIndicatorView(style: .medium)
  private var generating = false

  // Создаёт подсветку, знак закрепления, индикатор и две независимые области действий. Служба
  // доступности видит название и меню отдельно.
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .white
    isAccessibilityElement = false
    highlight.backgroundColor = UIColor(
      red: 235.0 / 255, green: 249.0 / 255, blue: 242.0 / 255, alpha: 1)
    highlight.layer.cornerRadius = 10
    highlight.isUserInteractionEnabled = false
    marker.tintColor = KandinskyPalette.studioMuted
    marker.contentMode = .scaleAspectFit
    busy.color = KandinskyPalette.studioMuted
    busy.hidesWhenStopped = true
    busy.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    openButton.contentHorizontalAlignment = .leading
    openButton.titleLabel?.numberOfLines = 1
    openButton.titleLabel?.lineBreakMode = .byTruncatingTail
    openButton.setTitleColor(KandinskyPalette.studioInk, for: .normal)
    actions.tintColor = KandinskyPalette.studioInk
    actions.setImage(
      UIImage(named: "KandinskyDrawerMore")?.withRenderingMode(.alwaysTemplate), for: .normal)
    actions.showsMenuAsPrimaryAction = true
    actions.accessibilityLabel = "Действия с чатом"
    for view in [highlight, marker, busy, openButton, actions] { contentView.addSubview(view) }
    accessibilityElements = [openButton, actions]
  }

  // Запрещает загрузку этой строки из сохранённой разметки. Её элементы должны быть созданы и
  // настроены вместе обычным способом.
  required init?(coder: NSCoder) { fatalError("Use programmatic initializer") }

  // Подставляет название, меню, выделение и признаки нового чата. Заново устанавливает подпись
  // озвучивания, чтобы состояние старой строки не досталось новой.
  func bind(_ row: StudioThread, selected: Bool, menu: UIMenu) {
    marker.image =
      row.pinned ? UIImage(named: "HeroiconsPaperClip")?.withRenderingMode(.alwaysTemplate) : nil
    generating = row.generating
    busy.accessibilityIdentifier = "chats.generating.\(row.id)"
    openButton.setTitle(row.title, for: .normal)
    openButton.titleLabel?.font = .systemFont(ofSize: 15, weight: selected ? .medium : .regular)
    openButton.accessibilityIdentifier = "chat.row.\(row.id)"
    openButton.accessibilityValue = generating ? "Генерация выполняется" : nil
    openButton.accessibilityTraits = selected ? [.button, .selected] : .button
    actions.accessibilityIdentifier = "chats.actions.\(row.id)"
    actions.menu = menu
    highlight.isHidden = !selected
    updateAnimation()
    setNeedsLayout()
  }

  // Перепроверяет, нужно ли движение индикатора после появления или снятия строки. Вне окна
  // индикатор не должен работать.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimation()
  }

  // Убирает состояние генерации и прежнее меню перед повторным использованием. Новая карточка не
  // покажет чужие действия до привязки.
  override func prepareForReuse() {
    super.prepareForReuse()
    generating = false
    busy.stopAnimating()
    actions.menu = nil
  }

  // Запускает индикатор только при генерации и наличии видимого окна. Невидимая строка не
  // расходует ресурсы на движение.
  private func updateAnimation() {
    if generating && window != nil { busy.startAnimating() } else { busy.stopAnimating() }
  }

  // Расставляет подсветку, индикатор и отдельную кнопку действий. Оставляет нужные поля под
  // закрепление и занятость, чтобы надпись не перекрывала кнопки.
  override func layoutSubviews() {
    super.layoutSubviews()
    highlight.frame = contentView.bounds.insetBy(dx: 8, dy: 1)
    marker.frame = CGRect(x: bounds.width - 80, y: bounds.midY - 9, width: 18, height: 18)
    busy.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
    busy.center = CGPoint(x: 23, y: bounds.midY)
    let left: CGFloat = generating ? 40 : 16
    let right: CGFloat = marker.image == nil ? 64 : 86
    openButton.frame = CGRect(
      x: left, y: 0, width: max(1, bounds.width - left - right), height: bounds.height)
    actions.frame = CGRect(x: bounds.width - 56, y: bounds.midY - 22, width: 44, height: 44)
  }
}
