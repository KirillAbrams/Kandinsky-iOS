import UIKit
@MainActor final class ScrollingDayBadge: UIView {
  let label: String
  let studio: Bool
  init(label: String, id: MessageID, studio: Bool) {
    self.label = label
    self.studio = studio
    super.init(frame: .zero)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    isAccessibilityElement = true
    accessibilityIdentifier = "chat.day.\(id)"
    accessibilityLabel = label
    accessibilityTraits = .staticText
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ rect: CGRect) {
    if studio {
      UIColor(red: 228.0 / 255, green: 240.0 / 255, blue: 231.0 / 255, alpha: 1).setFill()
      UIBezierPath(roundedRect: bounds, cornerRadius: 12).fill()
      let ink = UIColor(red: 62.0 / 255, green: 100.0 / 255, blue: 84.0 / 255, alpha: 1)
      KandinskyPalette.text(
        label, in: bounds.offsetBy(dx: 0, dy: 4), size: 12, color: ink, weight: .regular,
        alignment: .center)
      return
    }
    UIColor(red: 0.22, green: 0.42, blue: 0.23, alpha: 0.39).setFill()
    UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).fill()
    KandinskyPalette.text(
      label, in: bounds.offsetBy(dx: 0, dy: 4), size: 13, color: .white, weight: .semibold,
      alignment: .center)
  }
}
@MainActor final class ScrollingDays {
  private var views: [MessageID: ScrollingDayBadge] = [:]
  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMM"
    return f
  }()
  func apply(
    _ days: [HistoryDay], offset: CGFloat, width: CGFloat, container: UIView, studio: Bool = false
  ) -> [UIView] {
    let wanted = Set(days.map(\.messageID))
    for id in views.keys.filter({ !wanted.contains($0) }) {
      views.removeValue(forKey: id)?.removeFromSuperview()
    }
    return days.map { day in
      let date = Date(timeIntervalSince1970: Double(day.timestamp) / 1000)
      let label =
        Calendar.current.isDateInToday(date)
        ? "Сегодня" : formatter.string(from: date).replacingOccurrences(of: ".", with: "")
      let view: ScrollingDayBadge
      if let old = views[day.messageID], old.label == label, old.studio == studio {
        view = old
      } else {
        views.removeValue(forKey: day.messageID)?.removeFromSuperview()
        view = ScrollingDayBadge(label: label, id: day.messageID, studio: studio)
        views[day.messageID] = view
        container.addSubview(view)
      }
      let font = UIFont.systemFont(ofSize: studio ? 12 : 13, weight: studio ? .regular : .semibold)
      let w = min(
        max(1, width - 24),
        ceil((label as NSString).size(withAttributes: [.font: font]).width + (studio ? 20 : 24)))
      let height: CGFloat = studio ? 23 : 25
      view.frame = CGRect(
        x: (width - w) / 2, y: CGFloat(day.top) - offset + (CGFloat(day.height) - height) / 2,
        width: w, height: height)
      return view
    }
  }
  /// Очищает список владельцев, чтобы закрытая история не сохраняла невидимые плашки.
  func close() {
    views.values.forEach { $0.removeFromSuperview() }
    views.removeAll()
  }
}
