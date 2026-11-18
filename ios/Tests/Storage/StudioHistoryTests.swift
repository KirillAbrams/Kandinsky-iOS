// Проверяет деление чатов по дням, порядок закрепления и поведение повторно использованной строки
// списка.

import UIKit
import XCTest

@testable import Kandinsky

final class StudioHistoryTests: XCTestCase {
  // Собирает карточку с заданным временем и признаками закрепления и генерации. Тест меняет
  // именно эти параметры, не создавая целый чат и его сообщения.
  private func row(_ id: Int64, at time: Int64, pinned: Bool = false, generating: Bool = false)
    -> StudioThread
  {
    StudioThread(
      id: id, title: "Длинное название чата для проверки одной строки", lastSeq: 0,
      unreadCount: 0, pinned: pinned, archived: false, activityAtMs: time, generating: generating)
  }

  // Задаёт даты вокруг перевода часов и проверяет группы по местному календарю и порядок
  // закреплённых. Так подмена календарного дня сутками фиксированной длины сразу заметна.
  func testCalendarDaysAcrossDaylightSavingAndPinnedActivityOrder() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let iso = ISO8601DateFormatter()
    let now = try XCTUnwrap(iso.date(from: "2026-11-02T12:00:00Z"))
    // Превращает записанную дату в число для карточки. Все строки теста получают время в той же
    // мере, что и обычные данные приложения.
    func milliseconds(_ date: String) -> Int64 {
      Int64(iso.date(from: date)!.timeIntervalSince1970 * 1000)
    }
    let sections = StudioHistorySections.make(
      [
        row(1, at: milliseconds("2026-11-01T04:30:00Z")),
        row(2, at: milliseconds("2026-11-02T06:00:00Z")),
        row(3, at: 0),
        row(4, at: 10, pinned: true), row(5, at: 20, pinned: true),
      ], now: now, calendar: calendar)
    XCTAssertEqual(sections.map(\.title), ["Закреплённые", "Сегодня", "Вчера", "Ранее"])
    XCTAssertEqual(sections.map { $0.threads.map(\.id) }, [[5, 4], [2], [1], [3]])
    let promoted = StudioHistorySections.make(
      [row(1, at: Int64(now.timeIntervalSince1970 * 1000)), row(2, at: 1)], now: now,
      calendar: calendar)
    XCTAssertEqual(promoted.first?.title, "Сегодня")
    XCTAssertEqual(promoted.first?.threads.first?.id, 1)
  }

  // Проверяет, что индикатор генерации выключается при повторном использовании строки, а название
  // и кнопка действий не пересекаются. Иначе статус прежнего чата мог бы остаться у нового.
  @MainActor func testBusyCellStopsOnReuseAndKeepsActionsAndTitleApart() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let host = UIViewController()
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true }
    let cell = StudioThreadCell(style: .default, reuseIdentifier: "thread")
    cell.frame = CGRect(x: 0, y: 0, width: 304, height: 44)
    host.view.addSubview(cell)
    cell.bind(row(1, at: 1, pinned: true, generating: true), selected: true, menu: UIMenu())
    cell.layoutIfNeeded()
    let spinner = try XCTUnwrap(
      cell.contentView.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
    XCTAssertTrue(spinner.isAnimating)
    XCTAssertEqual(cell.openButton.accessibilityValue, "Генерация выполняется")
    XCTAssertEqual(cell.openButton.titleLabel?.numberOfLines, 1)
    XCTAssertLessThan(cell.openButton.frame.maxX, cell.actions.frame.minX)
    XCTAssertEqual(cell.actions.frame.width, 44)
    cell.prepareForReuse()
    XCTAssertFalse(spinner.isAnimating)
    cell.bind(row(2, at: 2), selected: false, menu: UIMenu())
    cell.layoutIfNeeded()
    XCTAssertFalse(spinner.isAnimating)
    XCTAssertNil(cell.openButton.accessibilityValue)
    XCTAssertEqual(cell.openButton.frame.minX, 16)
  }
}
