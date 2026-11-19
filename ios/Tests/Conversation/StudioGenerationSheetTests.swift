// Проверяет выбор модели, параметров генерации и недавних файлов на экране айфона. Использует
// условные возможности службы и отдельное окно для показа.

import UIKit
import XCTest
@testable import Kandinsky

@MainActor final class StudioGenerationSheetTests: XCTestCase {
  // Возвращает корневой элемент и всех его потомков. Поиск не зависит от вложенности панели,
  // когда её оформление меняется.
  private func views(in view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { views(in: $0) }
  }

  // Ищет элемент заданного вида по имени доступности. При отсутствии выдаёт ошибку с конкретным
  // именем.
  private func component<T: UIView>(
    _ type: T.Type, in sheet: StudioGenerationSheet, identifier: String
  ) throws -> T {
    try XCTUnwrap(views(in: sheet.view).compactMap { $0 as? T }.first {
      $0.accessibilityIdentifier == identifier
    }, identifier)
  }

  // Находит кнопку по видимому названию или подписи для озвучивания. Это позволяет одинаково
  // проверить текстовые и составные кнопки.
  private func button(_ title: String, in sheet: StudioGenerationSheet) throws -> UIButton {
    try XCTUnwrap(views(in: sheet.view).compactMap { $0 as? UIButton }.first {
      $0.currentTitle == title || $0.accessibilityLabel == title
    }, title)
  }

  // На время сценария открывает отдельное окно, а затем закрывает панель и возвращает прежний
  // фокус. Иначе проверка могла бы оставить чужое окно активным.
  private func withPresentationHost(
    _ run: (UIViewController) async throws -> Void
  ) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      host.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKey()
    }
    try await run(host)
  }

  // Меняет формат, размер, качество, длительность и количество, затем проверяет ползунок, предел
  // текста и слишком большое число. После исправления сверяет все переданные настройки.
  func testAdvancedSettingsKeepSelectedOptionsAndRejectAnOverflowingSeed() throws {
    let sheet = StudioGenerationSheet(options: KandinskyOptions(
      model: "video", aspect: "5:3", duration_seconds: 3, count: 2))
    let capabilities = StudioCapabilities(
      quality: [
        StudioChoice(id: "standard", name: "Обычное", sizes: nil),
        StudioChoice(id: "draft", name: "Черновое", sizes: nil)
      ],
      resolutions: [
        StudioChoice(id: "standard", name: "Стандартный", sizes: ["5:3": [800, 480], "3:5": [480, 800]]),
        StudioChoice(id: "compact", name: "Компактный", sizes: ["5:3": [640, 384], "3:5": [384, 640]])
      ],
      aspects: ["5:3", "3:5"], duration_seconds: [1, 3, 5], max_count: 4,
      negative_prompt: true, guidance: StudioGuidance(min: 1, max: 8, default: 4))
    var selectedCount: [Int] = []
    var submitted: [KandinskyOptions] = []
    sheet.showSettings(capabilities, onCountChange: { selectedCount.append($0) }) {
      submitted.append($0)
    }
    XCTAssertTrue(try button("5:3", in: sheet).isSelected)
    XCTAssertTrue(try button("800 × 480", in: sheet).isSelected)
    for name in ["3:5", "384 × 640", "Черновое", "1 с", "4", "Дополнительно"] {
      try button(name, in: sheet).sendActions(for: .touchUpInside)
    }
    let seed = try component(UITextField.self, in: sheet, identifier: "studio.settings.seed")
    let negative = try component(UITextView.self, in: sheet, identifier: "studio.settings.negative")
    let guidance = try component(UIControl.self, in: sheet, identifier: "studio.settings.guidance")
    for _ in 0..<20 { guidance.accessibilityIncrement() }
    guidance.accessibilityDecrement()
    XCTAssertEqual(guidance.accessibilityValue, "7.5")
    let limit = String(repeating: "a", count: 1999) + "🤝🏽"
    negative.text = limit + "z"
    negative.delegate?.textViewDidChange?(negative)
    XCTAssertEqual(negative.text, limit)
    negative.text = "  дым  "
    negative.delegate?.textViewDidChange?(negative)
    seed.text = "2147483648"
    try button("Готово", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertTrue(submitted.isEmpty)
    XCTAssertTrue(views(in: sheet.view).compactMap { $0 as? UILabel }.contains {
      $0.text == "Seed: число от 0 до 2147483647" && !$0.isHidden
    })
    seed.text = "2147483647"
    try button("Дополнительно", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertFalse(views(in: sheet.view).contains { $0 === seed })
    try button("Готово", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertEqual(selectedCount, [4])
    XCTAssertEqual(submitted, [KandinskyOptions(
      model: "video", aspect: "3:5", duration_seconds: 1, quality: "draft", resolution: "compact",
      count: 4, seed: 2147483647, negative_prompt: "дым", guidance_scale: 7.5
    )])
  }

  func testAccessibilityEscapeClosesSettingsWithoutApplyingAnUnconfirmedFormat() async throws {
    try await withPresentationHost { host in
      let sheet = StudioGenerationSheet(options: KandinskyOptions(model: "image", aspect: "5:3"))
      let limits = StudioCapabilities(
        quality: [], resolutions: [], aspects: ["5:3", "3:5"], duration_seconds: [],
        max_count: 1, negative_prompt: false, guidance: nil)
      var submitted: [KandinskyOptions] = []
      sheet.showSettings(limits, onCountChange: { _ in }) { submitted.append($0) }
      host.present(sheet, animated: false)
      XCTAssertTrue(sheet.view.accessibilityViewIsModal)
      let newFormat = try button("3:5", in: sheet)
      newFormat.sendActions(for: .touchUpInside)
      XCTAssertTrue(newFormat.isSelected)
      XCTAssertTrue(sheet.accessibilityPerformEscape())
      let dismissed = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in host.presentedViewController == nil }, object: nil)
      await fulfillment(of: [dismissed], timeout: 4)
      XCTAssertTrue(submitted.isEmpty)
    }
  }

  func testLongQualityChoicesWrapAndKeepTheirSelectionWhenThePanelWidens() throws {
    let sheet = StudioGenerationSheet(options: KandinskyOptions(model: "video", quality: "standard"))
    let choices = [
      StudioChoice(id: "standard", name: "Быстрая генерация", sizes: nil),
      StudioChoice(id: "high", name: "Высокое качество", sizes: nil)
    ]
    let limits = StudioCapabilities(
      quality: choices, resolutions: [], aspects: ["1:1"], duration_seconds: [],
      max_count: 1, negative_prompt: false, guidance: nil)
    var saved: KandinskyOptions?
    sheet.showSettings(limits, onCountChange: { _ in }) { saved = $0 }
    func layout(width: CGFloat) {
      sheet.view.frame = CGRect(x: 0, y: 0, width: width, height: 760)
      sheet.view.setNeedsLayout()
      sheet.view.layoutIfNeeded()
    }

    layout(width: 320)
    let standard = try button(choices[0].name, in: sheet)
    let high = try button(choices[1].name, in: sheet)
    XCTAssertGreaterThan(standard.frame.width, 0)
    XCTAssertGreaterThanOrEqual(high.frame.minY, standard.frame.maxY)
    high.sendActions(for: .touchUpInside)
    layout(width: 640)
    XCTAssertEqual(high.frame.minY, standard.frame.minY, accuracy: 0.5)
    XCTAssertGreaterThan(high.frame.minX, standard.frame.maxX)
    XCTAssertTrue(high.isSelected)
    try button("Готово", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertEqual(saved?.quality, "high")
  }

  // Передаёт прежние значения модели с урезанным набором возможностей. Проверяет скрытые поля и
  // замену недоступных вариантов, чтобы они не ушли в запрос.
  func testRemovedCapabilitiesDiscardStaleOptions() throws {
    let sheet = StudioGenerationSheet(options: KandinskyOptions(
      model: "video_sr", aspect: "3:5", duration_seconds: 3, quality: "draft", resolution: "compact",
      count: 4, seed: 9, negative_prompt: "дым", guidance_scale: 6))
    var submitted: [KandinskyOptions] = []
    sheet.showSettings(StudioCapabilities(
      quality: [], resolutions: [], aspects: ["1:1"], duration_seconds: [], max_count: 1,
      negative_prompt: false, guidance: nil), onCountChange: { _ in }) { submitted.append($0) }

    XCTAssertTrue(try button("1", in: sheet).isSelected)
    try button("Дополнительно", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertFalse(views(in: sheet.view).contains { view in
      view.accessibilityIdentifier == "studio.settings.negative"
        || view.accessibilityIdentifier == "studio.settings.guidance"
    })
    let seed = try component(UITextField.self, in: sheet, identifier: "studio.settings.seed")
    XCTAssertEqual(seed.text, "9")
    seed.text = ""
    try button("Готово", in: sheet).sendActions(for: .touchUpInside)
    XCTAssertEqual(submitted, [KandinskyOptions(
      model: "video_sr", quality: "standard", resolution: "standard", count: 1
    )])
  }

  // Проверяет, что закрытая панель не добавляет файлы, а открытая показывает первые пять. Нажатие
  // возвращает именно выбранный файл после ухода панели.
  func testRecentUploadsAreLimitedAndSelectionSurvivesDismissingTheSheet() async throws {
    try await withPresentationHost { host in
      let sheet = StudioGenerationSheet(options: KandinskyOptions())
      sheet.showAttachments { _ in XCTFail("Открываем только ранее загруженный файл") }
      let uploads = (0..<6).map { index in
        StudioUpload(blobId: "fixture-\(index)", mime: index.isMultiple(of: 2) ? "video/mp4" : "image/jpeg", byteSize: 100)
      }
      sheet.appendRecentUploads(uploads) { _ in XCTFail("Панель ещё закрыта") }
      XCTAssertFalse(views(in: sheet.view).contains { $0.accessibilityIdentifier == "studio.recent.fixture-0" })
      host.present(sheet, animated: false)
      let selected = expectation(description: "Выбор продолжается после закрытия панели")
      sheet.appendRecentUploads(uploads) { upload in
        XCTAssertEqual(upload.blobId, "fixture-1")
        XCTAssertEqual(upload.mime, "image/jpeg")
        selected.fulfill()
      }
      let identifiers = views(in: sheet.view).compactMap(\.accessibilityIdentifier)
        .filter { $0.hasPrefix("studio.recent.") }
      XCTAssertEqual(identifiers, uploads.prefix(5).map { "studio.recent." + $0.blobId })
      try component(UIButton.self, in: sheet, identifier: "studio.recent.fixture-1")
        .sendActions(for: .touchUpInside)
      await fulfillment(of: [selected], timeout: 3)
    }
  }

  // Проверяет пустой список и подсказку, затем открывает список с двумя моделями. Сверяет
  // выделение, описание и результат после закрытия окна.
  func testModelCatalogueShowsFailureAndReturnsTheChosenModelAfterDismissal() async throws {
    let empty = StudioGenerationSheet(options: KandinskyOptions())
    empty.showModels([]) { _ in XCTFail("Пустой список не должен предлагать модель") }
    XCTAssertTrue(views(in: empty.view).compactMap { $0 as? UILabel }.contains {
      $0.text == "Не удалось загрузить модели"
    })
    let catalogue = """
      [
        {
          "id": "image", "name": "Изображение", "description": "По описанию",
          "capabilities": {
            "quality": [], "resolutions": [], "aspects": ["1:1"],
            "duration_seconds": [], "max_count": 4, "negative_prompt": true
          }
        },
        {"id": "video_sr", "name": "Улучшение видео", "description": "По ролику"}
      ]
      """
    let models = try JSONDecoder().decode([StudioModel].self, from: Data(catalogue.utf8))
    try await withPresentationHost { host in
      let sheet = StudioGenerationSheet(options: KandinskyOptions(model: "image"))
      let selected = expectation(description: "Модель выбрана после закрытия панели")
      sheet.showModels(models) { model in
        XCTAssertEqual(model.id, "video_sr")
        XCTAssertEqual(model.description, "По ролику")
        XCTAssertNil(host.presentedViewController)
        selected.fulfill()
      }
      host.present(sheet, animated: false)
      XCTAssertTrue(try button("Изображение", in: sheet).accessibilityTraits.contains(.selected))
      let video = try button("Улучшение видео", in: sheet)
      XCTAssertFalse(video.accessibilityTraits.contains(.selected))
      XCTAssertEqual(video.accessibilityHint, "По ролику")
      video.sendActions(for: .touchUpInside)
      await fulfillment(of: [selected], timeout: 3)
    }
  }
}
