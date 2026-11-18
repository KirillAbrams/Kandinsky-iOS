import XCTest
import UIKit
@testable import Kandinsky
@MainActor final class GlassRenderingTests: XCTestCase {
  func testRepeatedLayoutKeepsHeaderDrawingUntilStatusOrWidthChanges() throws {
    let chrome = ConversationChrome(chatID: 3, onBack: {})
    chrome.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    chrome.layoutIfNeeded()
    let header = try XCTUnwrap(chrome.subviews.compactMap { $0 as? NativeGlassInk }.first)
    let paint = try XCTUnwrap(header.paint)
    var draws = 0
    header.paint = { rect in
      draws += 1
      paint(rect)
    }
    header.layer.displayIfNeeded()
    XCTAssertGreaterThan(draws, 0)
    let firstDraws = draws
    for _ in 0..<60 {
      chrome.setNeedsLayout()
      chrome.layoutIfNeeded()
      header.layer.displayIfNeeded()
    }
    XCTAssertEqual(draws, firstDraws)
    chrome.setNetworkStatus("Нет связи")
    XCTAssertTrue(header.layer.needsDisplay())
    header.layer.displayIfNeeded()
    chrome.setNetworkStatus("Нет связи")
    XCTAssertFalse(header.layer.needsDisplay())
    chrome.frame.size.width = 370
    chrome.layoutIfNeeded()
    XCTAssertTrue(header.layer.needsDisplay())
  }

  func testTypingUpdatesDraftWithoutRedrawingHeader() async throws {
    let harness = try await RepositoryHarness.open()
    let state = ConversationState(repository: harness.repo)
    try await state.open(chatID: 2)
    let chrome = ConversationChrome(chatID: 2, state: state, onBack: {})
    chrome.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    chrome.layoutIfNeeded()
    let header = try XCTUnwrap(chrome.subviews.compactMap { $0 as? NativeGlassInk }.first)
    header.layer.displayIfNeeded()
    let input = try XCTUnwrap(
      chrome.subviews.first { $0.accessibilityIdentifier == "composer.input" } as? UITextView)
    input.text = "Апельсиновое дерево"
    input.delegate?.textViewDidChange?(input)
    chrome.layoutIfNeeded()
    XCTAssertEqual(state.draft.text, input.text)
    XCTAssertFalse(header.layer.needsDisplay())
    chrome.persistAnchorAndClose()
    await state.close()
    try await harness.close()
  }
  func testUnchangedLayoutAndPeerStatusDoNotInvalidateWallpaper() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    let chrome = ConversationChrome(chatID: 3, onBack: {})
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.addSubview(chrome)
    chrome.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    chrome.layoutIfNeeded()
    defer {
      window.isHidden = true
      previous?.makeKey()
    }
    chrome.layer.displayIfNeeded()
    XCTAssertFalse(
      chrome.layer.needsDisplay(),
      "The initial backdrop must actually finish displaying before the observation")
    chrome.setNeedsLayout()
    chrome.layoutIfNeeded()
    let layoutInvalidates = chrome.layer.needsDisplay()
    chrome.layer.displayIfNeeded()
    chrome.setNetworkStatus("печатает…")
    let statusInvalidates = chrome.layer.needsDisplay()
    print(
      "KANDINSKY_WALLPAPER_INVALIDATION sameLayout=\(layoutInvalidates) statusOnly=\(statusInvalidates)"
    )
    XCTAssertFalse(layoutInvalidates, "An unchanged layout must retain the wallpaper backing store")
    XCTAssertFalse(
      statusInvalidates,
      "A peer-status update must repaint the header instead of the entire wallpaper")
    chrome.layer.displayIfNeeded()
    chrome.frame.size.width = 370
    chrome.setNeedsLayout()
    chrome.layoutIfNeeded()
    XCTAssertTrue(
      chrome.layer.needsDisplay(),
      "A real size change must still repaint the wallpaper and empty-state geometry")
  }
  func testChatWallpaperRemainsOpaqueAndLightBehindGlass() throws {
    let view = ConversationChrome(chatID: 3, onBack: {})
    view.frame = CGRect(x: 0, y: 0, width: 394, height: 852)
    view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      view.draw(view.bounds)
    }
    var rgba = [UInt8](repeating: 0, count: 394 * 852 * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &rgba, width: 394, height: 852, bitsPerComponent: 8, bytesPerRow: 394 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 394, height: 852))
    let p = (400 * 394 + 2) * 4
    XCTAssertEqual(rgba[p + 3], 255, "Wallpaper must stay opaque after material tint")
    XCTAssertGreaterThan(rgba[p + 1], 100, "Green wallpaper remains bright, not transparent black")
  }
  func testSystemBackdropChangesLiveAndForegroundStaysSharp() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }, window = UIWindow(windowScene: scene),
      root = UIViewController()
    root.overrideUserInterfaceStyle = .light
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKey()
    }
    let background = UIView(frame: root.view.bounds)
    background.backgroundColor = .red
    root.view.addSubview(background)
    for x in stride(from: 0, to: Int(root.view.bounds.width), by: 8) {
      let stripe = UIView(frame: CGRect(x: x, y: 0, width: 4, height: Int(root.view.bounds.height)))
      stripe.backgroundColor = .blue
      background.addSubview(stripe)
    }
    let panel = NativeGlassPanel(
      frame: CGRect(x: 20, y: 100, width: root.view.bounds.width - 40, height: 300))
    root.view.addSubview(panel)
    let foreground = UIView(frame: CGRect(x: 100, y: 200, width: 20, height: 20))
    foreground.backgroundColor = .black
    root.view.addSubview(foreground)
    root.view.layoutIfNeeded()
    func snapshot() -> UIImage {
      let f = UIGraphicsImageRendererFormat()
      f.scale = 1
      return UIGraphicsImageRenderer(size: window.bounds.size, format: f).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
    }
    func pixel(_ image: UIImage, _ x: Int, _ y: Int) throws -> [UInt8] {
      let cg = try XCTUnwrap(image.cgImage)
      var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
      let c = try XCTUnwrap(
        CGContext(
          data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
      let p = (y * cg.width + x) * 4
      return Array(bytes[p..<p + 4])
    }
    try await Task.sleep(nanoseconds: 400_000_000)
    let first = snapshot(), filtered = try pixel(first, 150, 150),
      sharp = try pixel(first, 110, 210)
    let attachment = XCTAttachment(image: first)
    attachment.name = "live-system-glass-stripes"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertGreaterThan(filtered[0], 40)
    XCTAssertGreaterThan(filtered[2], 40)
    XCTAssertLessThan(sharp[0], 20)
    XCTAssertLessThan(sharp[1], 20)
    XCTAssertLessThan(sharp[2], 20)
    background.subviews.forEach { $0.removeFromSuperview() }
    background.backgroundColor = .green
    try await Task.sleep(nanoseconds: 400_000_000)
    let changed = try pixel(snapshot(), 150, 150)
    XCTAssertGreaterThan(
      Int(changed[1]), Int(filtered[1]) + 30, "System glass must resample changing content")
  }

  func testStandardSizeKeepsEditorAndButtonsWithinReach() throws {
    let chrome = ConversationChrome(chatID: 3, onBack: {})
    chrome.frame = CGRect(x: 0, y: 0, width: 394, height: 852)
    chrome.layoutIfNeeded()
    func frame(_ name: String) throws -> CGRect {
      try XCTUnwrap(chrome.subviews.first { $0.accessibilityIdentifier == name }).frame
    }
    let editor = try frame("composer.input")
    let send = try frame("composer.send")
    let back = try frame("chat.back")
    XCTAssertEqual(editor.height, 48)
    XCTAssertGreaterThanOrEqual(send.height, 44)
    XCTAssertGreaterThanOrEqual(back.height, 44)
    XCTAssertLessThanOrEqual(editor.maxY, send.minY)
    XCTAssertLessThanOrEqual(send.maxY - editor.minY, 110)
    for rect in [editor, send, back] { XCTAssertTrue(chrome.bounds.contains(rect)) }
  }
}
