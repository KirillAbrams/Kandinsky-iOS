// Проверка камеры на устройстве без доступного заднего объектива. Она помогает поймать ошибку,
// при которой неудачная попытка снять фото оставляет камеру занятой.

import XCTest
import UIKit
import AVFoundation
@testable import Kandinsky
@MainActor final class PhotoCaptureAvailabilityTests: XCTestCase {
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
    capture.open(from: UIViewController()) { result in
      if case let .failure(error) = result {
        XCTAssertEqual(error as? MediaError, .unavailable)
      } else {
        XCTFail("No physical camera may produce a captured fixture.")
      }
      XCTAssertEqual(admission.captureActiveCount, 0)
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 3)
    media.close()
    admission.close()
    try await h.close()
  }
}
