import XCTest

final class AccountEntryUITests: XCTestCase {
  private func openFixtureHistory(_ app: XCUIApplication) throws {
    let row = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", "Плотная медиалента")
    ).firstMatch
    if !row.exists {
      let burger = app.buttons["chat.back"]
      if burger.waitForExistence(timeout: 12) { burger.tap() }
    }
    guard row.waitForExistence(timeout: 12) else {
      throw XCTSkip("Для проверки войдите в существующий аккаунт с медиалентой")
    }
    row.tap()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 20))
  }

  private func assertPreviewIsPlaying(_ app: XCUIApplication) {
    let remaining = app.staticTexts["studio.upload.remaining"]
    XCTAssertTrue(remaining.waitForExistence(timeout: 8))
    let first = remaining.label
    XCTAssertFalse(first.isEmpty)
    let advanced = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        remaining.exists && !remaining.label.isEmpty && remaining.label != first
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 9), .completed)
  }

  func testNewStudioHasReferenceActionsAndSamplePrompt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.textFields["chats.search.field"].exists)
    try openFixtureHistory(app)
    let new = app.buttons["chat.compose"]
    XCTAssertTrue(new.isHittable)
    new.tap()
    let sample = app.buttons["chat.welcome"]
    XCTAssertTrue(sample.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Что создадим?"].exists)
    let evidence = XCTAttachment(screenshot: app.screenshot())
    evidence.name = "Native Kandinsky — new studio"
    evidence.lifetime = .keepAlways
    add(evidence)
    sample.tap()
    let composer = app.textViews["composer.input"]
    XCTAssertEqual(
      composer.value as? String,
      "Белая магнолия у окна, мягкий дневной свет, минималистичная фотография")
    app.buttons["composer.plus"].tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Оживить фото из галереи"))
        .firstMatch.waitForExistence(timeout: 6))
    XCTAssertTrue(app.buttons["Снять фото"].exists)
    XCTAssertTrue(
      app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Загрузить и посмотреть видео")
      ).firstMatch.exists)
    let attachments = XCTAttachment(screenshot: app.screenshot())
    attachments.name = "Native Kandinsky — studio attachments"
    attachments.lifetime = .keepAlways
    add(attachments)
  }

  /// В новом разговоре повторно выбирает уже загруженное фото без повторного выбора в системной галерее.
  func testRecentUploadsReusePhotoAndPreviewVideo() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)
    let plus = app.buttons["composer.plus"]
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: plus)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
    plus.tap()
    XCTAssertTrue(app.staticTexts["Недавние загрузки"].waitForExistence(timeout: 12))
    let video = app.buttons["Посмотреть загруженное видео"].firstMatch
    if !video.isHittable { app.swipeUp() }
    XCTAssertTrue(video.isHittable)
    let choices = XCTAttachment(screenshot: app.screenshot())
    choices.name = "Native Kandinsky — recent uploads"
    choices.lifetime = .keepAlways
    add(choices)
    video.tap()
    XCTAssertTrue(app.buttons["studio.upload.expand"].waitForExistence(timeout: 18))
    app.buttons["studio.upload.dismiss"].tap()
    app.buttons["chat.compose"].tap()
    XCTAssertTrue(app.buttons["chat.welcome"].waitForExistence(timeout: 10))
    plus.tap()
    let photo = app.buttons["Использовать загруженное фото"].firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 12))
    if !photo.isHittable { app.swipeUp() }
    photo.tap()
    XCTAssertTrue(app.buttons["studio.reference.remove"].waitForExistence(timeout: 15))
    let marker = "IosRecentPhotoQA" + UUID().uuidString.prefix(8)
    print("ISOLATED_KANDINSKY_RECENT_PROMPT=\(marker)")
    let composer = app.textViews["composer.input"]
    composer.tap()
    composer.typeText(marker)
    app.buttons["composer.send"].tap()
    let cancel = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.cancel.")
    ).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 24))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Генерация отменена"].waitForExistence(timeout: 15))
  }

  func testRecentPhotoAndVideoCanBeOpenedWithoutSendingARequest() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)
    app.buttons["chat.compose"].tap()
    let plus = app.buttons["composer.plus"]
    let remove = app.buttons["studio.reference.remove"]
    let expand = app.buttons["studio.upload.expand"]
    let collapse = app.buttons["studio.upload.collapse"]

    func chooseRecent(_ title: String) {
      plus.tap()
      let choice = app.buttons[title].firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 15))
      if !choice.isHittable { app.swipeUp() }
      choice.tap()
    }
    chooseRecent("Использовать загруженное фото")
    XCTAssertTrue(remove.waitForExistence(timeout: 15))
    remove.tap()
    chooseRecent("Посмотреть загруженное видео")
    XCTAssertTrue(expand.waitForExistence(timeout: 20))
    assertPreviewIsPlaying(app)
    expand.tap()
    XCTAssertTrue(collapse.waitForExistence(timeout: 8))
    collapse.tap()
    app.buttons["studio.upload.dismiss"].tap()
    XCTAssertTrue(plus.waitForExistence(timeout: 8))
    XCTAssertFalse(remove.exists)
    app.buttons["chat.back"].tap()
    app.buttons["Плотная медиалента"].firstMatch.tap()
  }

  private func tapPickerThumbnail(_ thumbnail: XCUIElement, in app: XCUIApplication) {
    // Системная галерея публикует описание кадра отдельным элементом без действия нажатия.
    let frame = thumbnail.frame
    let origin = app.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
  }

  private func selectStudioPhoto(_ app: XCUIApplication) throws {
    try openFixtureHistory(app)
    app.buttons["chat.compose"].tap()
    XCTAssertTrue(app.buttons["chat.welcome"].waitForExistence(timeout: 10))
    app.buttons["composer.plus"].tap()
    let gallery = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Оживить фото из галереи")
    ).firstMatch
    XCTAssertTrue(gallery.waitForExistence(timeout: 8))
    gallery.tap()
    let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Photo"))
      .firstMatch
    XCTAssertTrue(
      photo.waitForExistence(timeout: 10),
      "Load the large Kandinsky HEIC fixture into the stand simulator")
    tapPickerThumbnail(photo, in: app)
    XCTAssertTrue(app.buttons["studio.reference.remove"].waitForExistence(timeout: 20))
  }

  func testSelectedPhotoReachesRecentUploadsBeforeSendingPrompt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try selectStudioPhoto(app)
    let evidence = XCTAttachment(screenshot: app.screenshot())
    evidence.name = "Native Kandinsky — uploaded photo chip"
    evidence.lifetime = .keepAlways
    add(evidence)
    let plus = app.buttons["composer.plus"]
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: plus)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 6), .completed)
    plus.tap()
    XCTAssertTrue(
      app.buttons["Использовать загруженное фото"].firstMatch.waitForExistence(timeout: 12))
    XCTAssertFalse(
      app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.cancel.")
      ).firstMatch.exists)
  }

  func testPhotoLabelKeepsSourceUntilDelete() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try selectStudioPhoto(app)

    let remove = app.buttons["studio.reference.remove"]
    XCTAssertEqual(remove.frame.width, 36, accuracy: 1)
    let center = remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.withOffset(CGVector(dx: -35, dy: 0)).tap()
    XCTAssertTrue(remove.exists)

    remove.tap()
    let deleted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: remove)
    XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 6), .completed)
    XCTAssertTrue(app.buttons["chat.welcome"].exists)
  }

  func testSelectedHeicSubmitsWithoutCaption() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try selectStudioPhoto(app)

    let send = app.buttons["composer.send"]
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: send)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
    send.tap()

    let welcome = app.buttons["chat.welcome"]
    let submitted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: welcome)
    XCTAssertEqual(XCTWaiter.wait(for: [submitted], timeout: 25), .completed)
    XCTAssertFalse(app.buttons["studio.reference.remove"].exists)
    if send.label == "Остановить генерацию" {
      send.tap()
      XCTAssertTrue(app.staticTexts["Генерация отменена"].waitForExistence(timeout: 15))
    }
  }

  func testSelectedHeicSubmitsVideoLiteSource() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try selectStudioPhoto(app)
    let evidence = XCTAttachment(screenshot: app.screenshot())
    evidence.name = "Native Kandinsky — HEIC reference"
    evidence.lifetime = .keepAlways
    add(evidence)

    let marker = "IosStudioHeicQA" + UUID().uuidString.prefix(8)
    print("ISOLATED_KANDINSKY_HEIC_PROMPT=\(marker)")
    let composer = app.textViews["composer.input"]
    composer.tap()
    composer.typeText(marker)
    app.buttons["composer.send"].tap()
    let cancel = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.cancel.")
    ).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 26))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Генерация отменена"].waitForExistence(timeout: 15))
  }

  func testSelectedVideoOpensMutedStudioPreview() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let composer = app.textViews["composer.input"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    try openFixtureHistory(app)
    let plus = app.buttons["composer.plus"]
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: plus)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
    plus.tap()
    let videos = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Загрузить и посмотреть видео")
    ).firstMatch
    XCTAssertTrue(videos.waitForExistence(timeout: 8))
    videos.tap()
    let clip = app.images.matching(
      NSPredicate(
        format:
          "label BEGINSWITH[c] %@", "Video, six seconds")
    ).firstMatch
    XCTAssertTrue(
      clip.waitForExistence(timeout: 10),
      "Load the six-second Kandinsky fixture into the stand simulator")
    tapPickerThumbnail(clip, in: app)
    let expand = app.buttons["studio.upload.expand"]
    XCTAssertTrue(expand.waitForExistence(timeout: 22))
    XCTAssertTrue(app.staticTexts["studio.upload.remaining"].exists)
    let preview = XCTAttachment(screenshot: app.screenshot())
    preview.name = "Native Kandinsky — uploaded video preview"
    preview.lifetime = .keepAlways
    add(preview)
    assertPreviewIsPlaying(app)
    expand.tap()
    let back = app.buttons["studio.upload.collapse"]
    XCTAssertTrue(back.waitForExistence(timeout: 8))
    let fullscreen = XCTAttachment(screenshot: app.screenshot())
    fullscreen.name = "Native Kandinsky — uploaded video fullscreen"
    fullscreen.lifetime = .keepAlways
    add(fullscreen)
    back.tap()
    XCTAssertTrue(expand.waitForExistence(timeout: 6))
    app.buttons["studio.upload.dismiss"].tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 8))
    XCTAssertFalse(expand.exists)
  }

  func testFirstStudioPromptReachesTheQueue() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let new = app.buttons["chat.compose"]
    XCTAssertTrue(new.waitForExistence(timeout: 15))
    new.tap()
    XCTAssertTrue(app.buttons["chat.welcome"].waitForExistence(timeout: 10))
    let composer = app.textViews["composer.input"]
    let marker = "IosFirstPromptQA" + UUID().uuidString.prefix(8)
    print("ISOLATED_KANDINSKY_PROMPT=\(marker)")
    composer.tap()
    composer.typeText(marker)
    XCTAssertEqual(composer.value as? String, marker)
    app.buttons["composer.send"].tap()
    let sent = app.staticTexts.matching(NSPredicate(format: "label == %@", marker)).firstMatch
    if !sent.waitForExistence(timeout: 18) {
      let diagnostic = XCTAttachment(screenshot: app.screenshot())
      diagnostic.name = "Native Kandinsky — after first submission"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
      print("KANDINSKY_AFTER_FIRST_SEND=" + app.debugDescription)
      XCTFail("The first prompt is not visible")
      return
    }
    let queued = app.staticTexts["В очереди"]
    XCTAssertTrue(queued.waitForExistence(timeout: 25))
    let cancel = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.cancel.")
    ).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 8))
    let waitingEvidence = XCTAttachment(screenshot: app.screenshot())
    waitingEvidence.name = "Native Kandinsky — waiting for generation"
    waitingEvidence.lifetime = .keepAlways
    add(waitingEvidence)
    let originalAction = cancel.identifier
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Генерация отменена"].waitForExistence(timeout: 15))
    let retry = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.retry.")
    ).firstMatch
    XCTAssertTrue(retry.waitForExistence(timeout: 8))
    XCTAssertEqual(
      originalAction.split(separator: ".").last, retry.identifier.split(separator: ".").last)
    let cancelledEvidence = XCTAttachment(screenshot: app.screenshot())
    cancelledEvidence.name = "Native Kandinsky — cancelled generation"
    cancelledEvidence.lifetime = .keepAlways
    add(cancelledEvidence)
    retry.tap()
    XCTAssertTrue(queued.waitForExistence(timeout: 20))
    XCTAssertTrue(cancel.waitForExistence(timeout: 8))
    XCTAssertNotEqual(originalAction, cancel.identifier)
    cancel.tap()
    XCTAssertFalse(cancel.waitForExistence(timeout: 2))
  }

  func testStudioSendTargetAndDrawerLayout() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 16))
    XCTAssertEqual(send.frame.width, 48, accuracy: 0.5)
    XCTAssertEqual(send.frame.height, 48, accuracy: 0.5)

    app.buttons["chat.back"].tap()
    let close = app.buttons["chats.drawer.close"]
    let newChat = app.buttons["chats.compose"]
    XCTAssertTrue(close.waitForExistence(timeout: 6))
    XCTAssertTrue(newChat.waitForExistence(timeout: 6))
    XCTAssertEqual(newChat.frame.minX, 16, accuracy: 0.5)
    XCTAssertEqual(newChat.frame.height, 52, accuracy: 0.5)
    XCTAssertTrue(app.textFields["chats.search.field"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Native Kandinsky — studio drawer geometry"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    close.tap()
    XCTAssertTrue(send.waitForExistence(timeout: 6))
  }

  /// После закрытия списка прежнее сообщение должно вернуться с допустимым отклонением положения.
  func testStudioDrawerReturnsToTheSameHistoryPosition() throws {
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)
    let row = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@", "chat.row.", "Плотная медиалента")
    ).firstMatch
    let burger = app.buttons["chat.back"]
    XCTAssertTrue(burger.waitForExistence(timeout: 20))
    let prompts = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "message."))
    let prompt = try XCTUnwrap(prompts.allElementsBoundByIndex.first(where: { $0.isHittable }))
    let id = prompt.identifier
    let position = prompt.frame.minY
    burger.tap()
    let close = app.buttons["chats.drawer.close"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["chats.search.field"].exists)
    XCTAssertTrue(app.buttons["chats.archive"].exists)
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "История запросов в приложении"
    capture.lifetime = .keepAlways
    add(capture)
    close.tap()
    XCTAssertTrue(burger.waitForExistence(timeout: 8))
    let returned = app.staticTexts[id]
    XCTAssertTrue(returned.waitForExistence(timeout: 10))
    XCTAssertEqual(returned.frame.minY, position, accuracy: 1)
  }

  /// Неудачная попытка не должна создавать прикреплённое фото, итоговый экран сохраняется снимком.
  func testUnavailableCameraKeepsStudioDraftAndShowsCameraMessage() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)
    app.buttons["chat.compose"].tap()
    let sample = app.buttons["chat.welcome"]
    XCTAssertTrue(sample.waitForExistence(timeout: 12))
    sample.tap()
    let input = app.textViews["composer.input"]
    let draft = input.value as? String
    XCTAssertFalse(draft?.isEmpty ?? true)
    let plus = app.buttons["composer.plus"]
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: plus)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
    plus.tap()
    let camera = app.buttons["Снять фото"]
    XCTAssertTrue(camera.waitForExistence(timeout: 6))
    camera.tap()
    let feedback = app.staticTexts["studio.attachment.error"]
    XCTAssertTrue(feedback.waitForExistence(timeout: 6))
    XCTAssertEqual(feedback.label, "Не удалось открыть камеру или галерею. Проверьте разрешения.")
    XCTAssertEqual(input.value as? String, draft)
    XCTAssertFalse(app.buttons["studio.reference.remove"].exists)
    captureAdvancedPanel(app, name: "Native Kandinsky — camera unavailable")
  }

  /// Сам вызов не читает серверные поля задания, поэтому это проверка ввода и сохранения настроек на
  /// экране.
  func testImageAdvancedFieldsReachTheOriginalJob() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)

    app.buttons["chat.compose"].tap()
    XCTAssertTrue(app.buttons["chat.welcome"].waitForExistence(timeout: 10))
    let settings = app.buttons["composer.settings"]
    let details = app.buttons["Дополнительно"]
    let panel = app.scrollViews["studio.panel.content"]
    let seed = app.textFields["studio.settings.seed"]
    let negative = app.textViews["studio.settings.negative"]
    let slider = app.descendants(matching: .any)["studio.settings.guidance"].firstMatch
    let done = app.buttons["Готово"]
    settings.tap()
    XCTAssertTrue(details.waitForExistence(timeout: 10))
    details.tap()
    XCTAssertTrue(slider.waitForExistence(timeout: 6))
    captureAdvancedPanel(app, name: "Native Kandinsky — expanded image settings")

    slider.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.5)).tap()
    XCTAssertTrue(app.staticTexts["Следование описанию 5.0"].exists)
    negative.tap()
    negative.typeText("No fog\nNo flare")
    XCTAssertEqual(negative.value as? String, "No fog\nNo flare")
    XCTAssertEqual(app.staticTexts["studio.settings.negative.count"].label, "15/2000")
    if !seed.isHittable { panel.swipeUp() }
    seed.tap()
    seed.typeText("41")
    if !done.isHittable { panel.swipeUp() }
    XCTAssertTrue(done.isHittable)
    done.tap()

    settings.tap()
    details.tap()
    XCTAssertEqual(seed.value as? String, "41")
    XCTAssertEqual(negative.value as? String, "No fog\nNo flare")
    XCTAssertTrue(app.staticTexts["Следование описанию 5.0"].exists)
    if !done.isHittable { panel.swipeUp() }
    done.tap()
    XCTAssertFalse(done.exists)

    let marker = "IosAdvancedQA" + UUID().uuidString.prefix(8)
    print("ISOLATED_KANDINSKY_ADVANCED_PROMPT=\(marker)")
    let composer = app.textViews["composer.input"]
    composer.tap()
    composer.typeText(marker)
    app.buttons["composer.send"].tap()
    let cancel = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "generation.action.cancel.")
    ).firstMatch
    XCTAssertTrue(cancel.waitForExistence(timeout: 24))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["Генерация отменена"].waitForExistence(timeout: 12))
  }

  private func captureAdvancedPanel(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testGenerationPanelsReflectServerCapabilities() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launch()
    try openFixtureHistory(app)
    let settings = app.buttons["composer.settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 20))
    settings.tap()
    let title = app.staticTexts["Параметры"]
    XCTAssertTrue(title.waitForExistence(timeout: 12))
    let firstChip = app.buttons["studio.option.Качество.draft"]
    XCTAssertEqual(firstChip.frame.height, 48, accuracy: 0.5)
    XCTAssertEqual(firstChip.frame.minY - title.frame.minY, 77, accuracy: 0.5)
    XCTAssertTrue(app.buttons["studio.option.Качество.draft"].exists)
    XCTAssertFalse(app.staticTexts["Длительность"].exists)
    app.buttons["studio.option.Формат.5:3"].tap()
    XCTAssertEqual(app.buttons["studio.option.Размер.standard"].label, "1280 × 768")
    let imageSettings = XCTAttachment(screenshot: app.screenshot())
    imageSettings.name = "Native Kandinsky — image generation settings"
    imageSettings.lifetime = .keepAlways
    add(imageSettings)
    app.buttons["Готово"].tap()

    app.buttons["composer.model"].tap()
    let video = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Video Lite"))
      .firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["Улучшить видео"].exists)
    XCTAssertEqual(video.frame.height, 72, accuracy: 0.5)
    let models = XCTAttachment(screenshot: app.screenshot())
    models.name = "Native Kandinsky — models"
    models.lifetime = .keepAlways
    add(models)
    video.tap()
    settings.tap()
    XCTAssertTrue(app.staticTexts["Длительность"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["studio.option.Качество.draft"].exists)
    XCTAssertTrue(app.buttons["studio.option.Количество.4"].exists)
    XCTAssertEqual(app.buttons["studio.option.Размер.standard"].label, "800 × 480")
    let videoSettings = XCTAttachment(screenshot: app.screenshot())
    videoSettings.name = "Native Kandinsky — video generation settings"
    videoSettings.lifetime = .keepAlways
    add(videoSettings)
    app.buttons["studio.option.Длительность.3"].tap()
    app.buttons["Дополнительно"].tap()
    let seed = app.textFields["Seed"]
    XCTAssertTrue(seed.waitForExistence(timeout: 6))
    captureAdvancedPanel(app, name: "Native Kandinsky — expanded video settings")
    XCTAssertFalse(app.textViews["studio.settings.negative"].exists)
    if !seed.isHittable { app.swipeUp() }
    seed.tap()
    seed.typeText("23")
    let done = app.buttons["Готово"]
    let content = app.scrollViews["studio.panel.content"]
    if !done.isHittable { content.swipeUp() }
    XCTAssertTrue(done.isHittable)
    done.tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 6))
    settings.tap()
    app.buttons["Дополнительно"].tap()
    XCTAssertEqual(seed.value as? String, "23")
    app.buttons["studio.panel.dismiss"].tap()
    XCTAssertTrue(settings.waitForExistence(timeout: 6))
  }

  func testExistingMediaHistory() throws {
    let app = XCUIApplication()
    app.launch()
    let history = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.row.", "Плотная медиалента")
    ).firstMatch
    guard history.waitForExistence(timeout: 12) else {
      throw XCTSkip("Для проверки войдите в существующий аккаунт с медиалентой")
    }
    history.tap()
    XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["composer.model"].exists)
    let evidence = XCTAttachment(screenshot: app.screenshot())
    evidence.name = "Native Kandinsky — media history"
    evidence.lifetime = .keepAlways
    add(evidence)

    let share = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "media.action.share.")
    ).firstMatch
    XCTAssertTrue(share.waitForExistence(timeout: 20))
    share.tap()
    let shareSheet = app.collectionViews.firstMatch
    XCTAssertTrue(
      shareSheet.waitForExistence(timeout: 25), "Должен открыться системный выбор получателя")
    let sheet = XCTAttachment(screenshot: app.screenshot())
    sheet.name = "Native Kandinsky — share original"
    sheet.lifetime = .keepAlways
    add(sheet)

    app.buttons["Close"].tap()
    let save = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "media.action.save.")
    ).firstMatch
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    save.tap()
    let confirm = app.buttons["Save"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 25), "Должен открыться системный выбор папки")
    let picker = XCTAttachment(screenshot: app.screenshot())
    picker.name = "Native Kandinsky — save original"
    picker.lifetime = .keepAlways
    add(picker)
  }
}
