import UIKit
import ImageIO
import UniformTypeIdentifiers

struct StudioPhotoEncoder {
  func jpeg(_ image: CGImage, to url: URL, cancel: () -> Bool = { false }) throws {
    guard url.isFileURL, !cancel() else { throw MediaError.cancelled }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: url) } }
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw MediaError.io }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: 1]
        as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw MediaError.io }
    guard !cancel() else { throw MediaError.cancelled }
    completed = true
  }
}
