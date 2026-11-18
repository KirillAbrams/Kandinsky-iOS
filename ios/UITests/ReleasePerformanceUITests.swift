// Проверяем открытие и прокрутку длинной истории через обычные жесты и собираем показания
// времени, памяти и процессора.

import XCTest

final class ReleasePerformanceUITests: XCTestCase {
  // Открываем историю из меню и ждём появления поля ввода. Так следующий жест попадает в чат,
  // который закончил открываться.
  private func openLongHistory(_ app: XCUIApplication) throws {
    let menu = app.buttons["chat.back"]
    XCTAssertTrue(menu.waitForExistence(timeout: 15))
    menu.tap()
    let row = app.buttons["Длинная история"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 12))
  }

  // Запускаем приложение со сбором показаний и открываем длинную историю. При отсутствии
  // сохранённого входа проверка пропускается без создания аккаунта.
  private func start() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--metrics"]
    app.launch()
    if app.textFields["account.username"].exists {
      throw XCTSkip("Войдите в существующий аккаунт с длинной историей")
    }
    try openLongHistory(app)
    return app
  }

  // В ограниченное время повторяем быстрые жесты по готовым строкам или в сторону старых страниц.
  // Снимаем время, память, затраты процессора и поддерживаемые признаки задержек прокрутки.
  private func measureScrolling(_ app: XCUIApplication, olderPages: Bool) {
    let options = XCTMeasureOptions()
    options.iterationCount = 1
    var metrics: [XCTMetric] = [
      XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
      XCTOSSignpostMetric.scrollingAndDecelerationMetric
    ]
    if #available(iOS 19.0, *) { metrics.append(XCTHitchMetric(application: app)) }
    let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: olderPages ? 0.25 : 0.45))
    let bottom = app.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: olderPages ? 0.75 : 0.58))
    let seconds =
      ProcessInfo.processInfo.environment["KANDINSKY_SCROLL_SECONDS"].flatMap(Int.init) ?? 30
    measure(metrics: metrics, options: options) {
      let end = Date().addingTimeInterval(TimeInterval(min(120, max(2, seconds))))
      var towardOlder = true
      repeat {
        let start = towardOlder ? top : bottom
        let finish = towardOlder ? bottom : top
        start.press(
          forDuration: 0.06, thenDragTo: finish, withVelocity: .fast, thenHoldForDuration: 0)
        if !olderPages { towardOlder.toggle() }
      } while Date() < end
    }
    XCTAssertTrue(app.textViews["composer.input"].exists)
  }

  // Прокручиваем длинную историю назад и вперёд и сверяем смену набора видимых строк. Наличие
  // формы ввода после жестов показывает, что экран остался открыт.
  func testLongHistoryScrollsInBothDirections() throws {
    let app = try start()
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'message.' OR identifier BEGINSWITH 'generation.slot.' OR identifier BEGINSWITH 'media.image.'"))
    // Собираем номера только тех сообщений и вложений, с которыми сейчас можно взаимодействовать.
    // Скрытые элементы не должны выдавать себя за прокрученные строки.
    func visibleRows() -> Set<String> {
      Set(rows.allElementsBoundByIndex.filter { $0.isHittable }.map(\.identifier))
    }
    // Ждём появления хотя бы одного нового видимого номера. Пустой список и прежний состав не
    // подтверждают перемещение.
    func waitForRows(differentFrom previous: Set<String>) -> Set<String> {
      var current = Set<String>()
      let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        current = visibleRows()
        return !current.isEmpty && !current.subtracting(previous).isEmpty
      }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 12), .completed)
      return current
    }
    let before = waitForRows(differentFrom: [])
    let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.28))
    let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.69))
    upper.press(forDuration: 0.08, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
    let older = waitForRows(differentFrom: before)
    lower.press(forDuration: 0.08, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.3)
    _ = waitForRows(differentFrom: older)
    XCTAssertTrue(app.textViews["composer.input"].exists)
  }

  // Собираем показания при коротких жестах туда и обратно по уже подготовленной истории.
  // Отдельный сценарий даёт замер без постоянного ухода за пределы готовых строк.
  func testReadyRowsNativeMetrics() throws {
    measureScrolling(try start(), olderPages: false)
  }

  // Прокручиваем в сторону более старых страниц с большим размахом. Замер включает работу,
  // которая появляется при выходе за пределы готовых строк.
  func testNewPagesNativeMetrics() throws {
    measureScrolling(try start(), olderPages: true)
  }

  // Двадцать раз открываем длинную историю из меню подряд. Повторяем путь в одном запущенном
  // приложении, чтобы заметить сбой при переиспользовании экрана.
  func testTwentyWarmOpens() throws {
    let app = try start()
    for _ in 0..<20 { try openLongHistory(app) }
  }
}
