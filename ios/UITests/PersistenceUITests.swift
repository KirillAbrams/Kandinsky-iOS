// Проверяем, что существующие чаты и черновик переживают завершение приложения. Для отметки берём
// пустое поле и после проверки очищаем её.

import XCTest

final class PersistenceUITests: XCTestCase {
  // Открываем список, находим оба исходных чата и добавляем проверочную строку в свободный
  // черновик. После нового запуска сверяем её наличие и возвращаем поле к пустому виду.
  func testExistingChatAndDraftSurviveRelaunch() throws {
    let app = XCUIApplication()
    app.activate()
    let menu = app.buttons["chat.back"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 20))
    menu.tap()
    let dense = app.buttons["Плотная медиалента"].firstMatch
    let long = app.buttons["Длинная история"].firstMatch
    XCTAssertTrue(dense.waitForExistence(timeout: 10))
    XCTAssertTrue(long.exists)
    long.tap()
    let input = app.textViews["composer.input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    let marker = "Restored draft"
    // Ставим курсор после отметки и удаляем столько знаков, сколько ввели. Проверяем пустое поле,
    // чтобы отметка не осталась в истории черновика.
    func eraseMarker() throws {
      // После запуска курсор может стоять в начале строки. Сначала ставим его после последней буквы.
      input.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
      input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: marker.count))
      XCTAssertTrue((input.value as? String ?? "").isEmpty)
    }
    if input.value as? String == marker { try eraseMarker() }
    let previous = input.value as? String ?? ""
    guard previous.isEmpty || previous == input.label else {
      throw XCTSkip("В выбранном чате уже есть черновик владельца")
    }
    input.tap()
    input.typeText(marker)
    XCTAssertTrue((input.value as? String ?? "").hasSuffix(marker))
    XCUIDevice.shared.press(.home)
    Thread.sleep(forTimeInterval: 1)
    app.terminate()
    app.launch()
    XCTAssertTrue(input.waitForExistence(timeout: 20))
    XCTAssertTrue(
      (input.value as? String ?? "").hasSuffix(marker),
      "Черновик в выбранном чате после завершения процесса")
    try eraseMarker()
    XCUIDevice.shared.press(.home)
    app.activate()
  }
}
