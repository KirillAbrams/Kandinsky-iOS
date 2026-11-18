import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class PhotoOcclusionTests: XCTestCase {
  private final class DismissPan: UIPanGestureRecognizer {
    override var state: UIGestureRecognizer.State {
      get { .changed }
      set {}
    }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: 80) }
  }
  /// Читает пиксель вне медиа и кнопок, чтобы подтвердить чёрную подложку.
  func testPhotoBackingIncludesStatusAreaAndStaysOpaqueDuringDrag() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store)
    let a = Attachment(
      id: "opaque-photo", relativePath: "objects/not-yet-loaded.jpg", mime: "image/jpeg",
      byteSize: 100, rawWidth: 600, rawHeight: 400, orientation: 1, durationMs: 0,
      thumbnailKey: "opaque-photo")
    let
      scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first),
      previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    root.view.backgroundColor = .magenta
    window.rootViewController = root
    window.makeKeyAndVisible()
    let viewer = PhotoViewerController(attachment: a, media: media)
    defer {
      viewer.dismiss(animated: false)
      media.close()
      window.isHidden = true
      previous?.makeKey()
    }
    root.view.frame = window.bounds
    window.layoutIfNeeded()
    await withCheckedContinuation { continuation in
      root.present(viewer, animated: false) { continuation.resume() }
    }
    viewer.view.layoutIfNeeded()
    XCTAssertEqual(
      viewer.view.convert(viewer.view.bounds, to: window), window.bounds,
      "The gallery covers the status area as well as the chat")
    _ = viewer.perform(NSSelectorFromString("dragged:"), with: DismissPan())
    XCTAssertEqual(
      viewer.view.backgroundColor?.cgColor.alpha, 1,
      "An unfinished drag must not expose the underlying chat")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: viewer.view.bounds.size, format: format).image {
      viewer.view.layer.render(in: $0.cgContext)
    }
    let cg = try XCTUnwrap(image.cgImage), data = try XCTUnwrap(cg.dataProvider?.data) as Data
    // Верхняя левая точка находится вне медиа и кнопок, включая безопасную системную область
    let i = 2 * cg.bytesPerRow + 2 * 4
    XCTAssertLessThan(Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]), 12)
    await withCheckedContinuation { continuation in
      viewer.dismiss(animated: false) { continuation.resume() }
    }
    try await h.close()
  }
}
