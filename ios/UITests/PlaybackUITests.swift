// Открываем настоящие фото и видео из существующей медиаленты и проверяем управление просмотром.

import XCTest

final class PlaybackUITests: XCTestCase {
  // Используем уже открытый аккаунт, заходим в «Плотную медиаленту» и находим доступные элементы.
  // Проверяем переход в просмотр и возврат к видео в ленте.
  func testPhotoAndVideoOpenFromExistingMediaHistory() throws {
    let app = XCUIApplication()
    app.launch()
    let menu = app.buttons["chat.back"]
    guard menu.waitForExistence(timeout: 10) else {
      throw XCTSkip("Для просмотра медиа нужен вход в существующий аккаунт")
    }
    menu.tap()
    let history = app.buttons["Плотная медиалента"]
    XCTAssertTrue(history.waitForExistence(timeout: 10))
    history.tap()

    // Ищем кнопку по точной надписи и при необходимости прокручиваем несколько экранов. Подходит
    // только кнопка, которую действительно можно нажать.
    func visibleButton(_ label: String) throws -> XCUIElement {
      let buttons = app.buttons.matching(NSPredicate(format: "label == %@", label))
      for _ in 0..<8 {
        if let button = buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
          return button
        }
        app.swipeDown()
      }
      return try XCTUnwrap(buttons.allElementsBoundByIndex.first(where: { $0.isHittable }))
    }

    try visibleButton("Открыть фотографию").tap()
    let close = app.buttons["photo.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 10))
    close.tap()
    try visibleButton("На весь экран").tap()
    let inline = app.buttons["player.inline"]
    XCTAssertTrue(inline.waitForExistence(timeout: 10))
    inline.tap()
  }
}
