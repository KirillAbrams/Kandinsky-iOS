import XCTest
import UIKit
@testable import Kandinsky

@MainActor final class EmojiComposerTests: XCTestCase {
  func testNativeTextInputDrawsColoredZWJBeforeAnyChatLayout() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    let chrome = ConversationChrome(chatID: 3, onBack: {})
    root.view = chrome
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKey()
    }
    window.layoutIfNeeded()
    let input = try XCTUnwrap(
      chrome.subviews.first { $0.accessibilityIdentifier == "composer.input" } as? UITextView)
    // Цвет курсора не должен попадать в измерение цвета самого знака.
    input.tintColor = .clear
    XCTAssertTrue(input.becomeFirstResponder())
    input.insertText("👨‍👩‍👧‍👦")
    XCTAssertEqual(input.text.count, 1)
    if let manager = input.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
    try await Task.sleep(nanoseconds: 500_000_000)
    window.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let screen = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let bounds = input.convert(input.bounds, to: window).applying(
      CGAffineTransform(scaleX: 2, y: 2))
    let image = try XCTUnwrap(screen.cgImage?.cropping(to: bounds))
    let attachment = XCTAttachment(image: UIImage(cgImage: image))
    attachment.lifetime = .keepAlways
    attachment.name = "Введённый эмодзи"
    add(attachment)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let coloredPixels = (0..<(image.width * image.height)).filter { pixel in
      let offset = pixel * 4
      let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2])
      return max(red, green, blue) - min(red, green, blue) > 35
    }
    XCTAssertGreaterThan(coloredPixels.count, 25)
    input.resignFirstResponder()
  }
}
