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

  @MainActor func testHistoryAndArchiveCanRetryTheirOwnFailedReads() async throws {
    let harness = try await RepositoryHarness.open()
    let profile = NetworkProfile(
      userId: 7, deviceId: "archive-fixture", name: "Проверка",
      token: String(repeating: "a", count: 64), expiresAtMs: Int64.max)
    let page = Data(
      #"{"threads":[{"id":42,"title":"Сохранённый архив","lastSeq":4,"unreadCount":0,"pinned":false,"archived":true}]}"#.utf8)
    let api = ScriptedHTTP.makeAPI([.response(503, Data()), .response(200, page)], profile: profile)
    let sync = NetworkSync(profile: profile, store: harness.store, local: harness.repo, api: api)
    defer { sync.close() }

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      host.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    let opened = expectation(description: "Открыта карточка из ответа сервера")
    let drawer = StudioHistoryController(
      network: sync, selected: nil, onOpen: { chat in
        XCTAssertEqual(chat, 42)
        opened.fulfill()
      }, onCompose: { XCTFail("Новый чат не запрашивался") },
      onLogout: {}, onEraseAccount: {}, onDeleted: { _ in XCTFail("Чат не удалялся") })
    host.present(drawer, animated: false)

    let archive = try XCTUnwrap(findView("chats.archive", in: drawer.view) as? UIButton)
    let table = try XCTUnwrap(findView("chats.rows", in: drawer.view) as? UITableView)
    func waitForFooter(_ title: String) async throws -> UIButton {
      for _ in 0..<150 {
        if let footer = table.tableFooterView as? UIButton, footer.title(for: .normal) == title {
          return footer
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      let footer = table.tableFooterView as? UIButton
      XCTAssertEqual(footer?.title(for: .normal), title, "Нижняя строка списка должна предложить повтор")
      return try XCTUnwrap(footer)
    }

    let retryLocal = try await waitForFooter("Повторить загрузку")
    XCTAssertTrue(retryLocal.isEnabled)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)
    try await harness.store.perform { try NetworkSchema.install($0) }
    try await sync.admitStudioThread(row(41, at: 10))
    retryLocal.sendActions(for: .touchUpInside)
    for _ in 0..<150 {
      if drawer.numberOfSections(in: table) == 1,
        drawer.tableView(table, numberOfRowsInSection: 0) == 1
      { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    table.layoutIfNeeded()
    let local = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? StudioThreadCell)
    XCTAssertEqual(local.openButton.title(for: .normal), row(41, at: 10).title)
    XCTAssertTrue(ScriptedHTTP.requests().isEmpty)

    archive.sendActions(for: .touchUpInside)
    let retry = try await waitForFooter("Повторить загрузку")
    XCTAssertTrue(retry.isEnabled)
    retry.sendActions(for: .touchUpInside)

    for _ in 0..<150 {
      if drawer.numberOfSections(in: table) == 1, drawer.tableView(table, numberOfRowsInSection: 0) == 1 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(drawer.numberOfSections(in: table), 1)
    guard drawer.numberOfSections(in: table) == 1 else { return }
    XCTAssertEqual(drawer.tableView(table, numberOfRowsInSection: 0), 1)
    guard drawer.tableView(table, numberOfRowsInSection: 0) == 1 else { return }
    let cell = try XCTUnwrap(drawer.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)) as? StudioThreadCell)
    XCTAssertEqual(cell.openButton.title(for: .normal), "Сохранённый архив")
    try await harness.store.perform { db in
      try db.execute("""
        CREATE TRIGGER refuse_archive_insert BEFORE INSERT ON net_chats
        WHEN NEW.chatID=42 BEGIN SELECT RAISE(ABORT,'archive write refused'); END
        """)
    }
    cell.openButton.sendActions(for: .touchUpInside)
    let refused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      (drawer.presentedViewController as? UIAlertController)?.title == "Не удалось выполнить действие"
    }, object: nil)
    await fulfillment(of: [refused], timeout: 4)
    let alert = try XCTUnwrap(drawer.presentedViewController as? UIAlertController)
    XCTAssertEqual(alert.actions.map(\.title), ["Понятно"])
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats WHERE chatID=42"), 0)
    let closed = expectation(description: "Сообщение об ошибке закрыто")
    alert.dismiss(animated: false) { closed.fulfill() }
    await fulfillment(of: [closed], timeout: 4)
    try await harness.store.perform { try $0.execute("DROP TRIGGER refuse_archive_insert") }
    cell.openButton.sendActions(for: .touchUpInside)
    await fulfillment(of: [opened], timeout: 4)
    let requests = ScriptedHTTP.requests()
    XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/kandinsky/threads", "/v1/kandinsky/threads"])
    XCTAssertEqual(requests.map { $0.url?.query }, Array(repeating: "view=archive&q=&offset=0&limit=30", count: 2))
    XCTAssertEqual(try harness.rawScalar("SELECT count(*) FROM net_chats WHERE chatID=42"), 1)
    try await harness.close()
  }

  @MainActor private func findView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id { return view }
    return view.subviews.lazy.compactMap { self.findView(id, in: $0) }.first
  }
}
