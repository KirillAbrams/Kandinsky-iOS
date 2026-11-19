// Проверяет освобождение экрана камеры и ответ при недоступном заднем объективе.

import XCTest
import UIKit
import AVFoundation
@testable import Kandinsky
@MainActor final class PhotoCaptureAvailabilityTests: XCTestCase {
  func testCameraControlsRejectDuplicateCaptureAndReleaseTheCameraScreen() throws {
    var acceptCapture = false
    var attempts = 0
    var cancels = 0
    weak var releasedScreen: UIViewController?
    weak var releasedShutter: UIButton?
    try autoreleasepool {
      let session = AVCaptureSession()
      let screen = PhotoCaptureController.makeScreen(
        session: session, onCancel: { cancels += 1 },
        onCapture: {
          attempts += 1
          return acceptCapture
        })
      releasedScreen = screen.controller
      let controls = screen.controller.view.subviews.compactMap { $0 as? UIButton }
      let shutter = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "capture.photo" })
      let cancel = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "capture.cancel" })
      releasedShutter = shutter
      XCTAssertTrue(screen.preview.session === session)
      shutter.sendActions(for: .touchUpInside)
      XCTAssertTrue(shutter.isEnabled)
      acceptCapture = true
      shutter.sendActions(for: .touchUpInside)
      XCTAssertFalse(shutter.isEnabled)
      shutter.sendActions(for: .touchUpInside)
      XCTAssertEqual(attempts, 2)
      cancel.sendActions(for: .touchUpInside)
      XCTAssertEqual(cancels, 1)
    }
    XCTAssertNil(releasedScreen)
    XCTAssertNil(releasedShutter, "The action attached to the shutter must release its button")
  }

  // Запрашиваем снимок там, где система не видит заднюю камеру. Ждём сообщение о недоступности и
  // проверяем, что место для съёмки осталось свободным. С настоящей камерой этот сценарий
  // пропускается.
  func testMissingSimulatorCameraIsReportedWithoutTakingCaptureLease() async throws {
    guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) == nil
    else {
      throw XCTSkip(
        "This probe checks an unavailable camera; real capture is a separate hardware gate.")
    }
    let h = try await RepositoryHarness.open(), admission = MediaAdmission()
    let media = MediaStore(store: h.store),
      capture = PhotoCaptureController(media: media, admission: admission)
    let done = expectation(description: "camera unavailability")
    done.assertForOverFulfill = true
    capture.open(from: UIViewController()) { result in
      if case let .failure(error) = result {
        XCTAssertEqual(error as? MediaError, .unavailable)
      } else {
        XCTFail("No physical camera may produce a captured fixture.")
      }
      XCTAssertEqual(admission.captureActiveCount, 0)
      done.fulfill()
    }
    capture.cancel()
    capture.cancel()
    await fulfillment(of: [done], timeout: 3)
    media.close()
    admission.close()
    try await h.close()
  }
}
