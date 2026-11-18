import XCTest

final class AccountLiveUITests: XCTestCase {
  func testAccountCanOpenBothOriginalHistories() throws {
    let app = XCUIApplication()
    app.launch()
    let menu = app.buttons["chat.back"]
    guard menu.waitForExistence(timeout: 10) else {
      throw XCTSkip("Для просмотра истории нужен вход в существующий аккаунт")
    }
    for title in ["Плотная медиалента", "Длинная история"] {
      menu.tap()
      let row = app.buttons.matching(
        NSPredicate(
          format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", title
        )
      ).firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      row.tap()
      XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 10))
    }
  }
}
