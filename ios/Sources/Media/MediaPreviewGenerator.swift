// Делает отдельную уменьшенную картинку для фото или видео и ещё меньшую размытую копию. Их
// размер ограничен, чтобы показать их без передачи оригинала.

import Foundation
import ImageIO
import AVFoundation
import CryptoKit
import CoreImage
import UniformTypeIdentifiers

enum MediaPreviewGenerator {
  /// Использует криптографический отпечаток пути, чтобы не переносить его знаки в имя файла.
  // Получает постоянное имя из контрольной суммы пути. Знаки исходного пути не становятся частью
  // имени уменьшенной копии.
  static func derivedName(_ relative: String) -> String {
    let hash = SHA256.hash(data: Data(relative.utf8)).map { String(format: "%02x", $0) }.joined()
    return "local-" + hash + ".jpg"
  }
  // Проверяет папку и повторно использует готовую копию. Для видео извлекает первый кадр, для
  // фото читает уменьшенное изображение с поправкой поворота. Убирает только старые производные
  // копии.
  static func normalFile(root: URL, relative: String, file: URL, mime: String) throws -> URL {
    let directory = root.appendingPathComponent("media/previews")
    guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else {
      throw MediaError.corrupt
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent(derivedName(relative))
    if FileManager.default.fileExists(atPath: target.path) { return target }
    let image: CGImage
    if mime.hasPrefix("video/") {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 320, height: 320)
      image = try generator.copyCGImage(at: .zero, actualTime: nil)
    } else {
      guard
        let source = CGImageSourceCreateWithURL(
          file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
            kCGImageSourceCreateThumbnailWithTransform: true
          ] as CFDictionary)
      else { throw MediaError.corrupt }
      image = thumbnail
    }
    try jpeg(image, quality: 0.78).write(to: target, options: .atomic)
    // Эта очистка затрагивает только производные уменьшенные копии, исходники и вложения сюда не входят
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))?.filter {
        $0.lastPathComponent.hasPrefix("local-")
      } ?? []
    if files.count > 128 {
      let oldest = files.filter { $0 != target }.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
          < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
      }
      for file in oldest.prefix(files.count - 128) { try? FileManager.default.removeItem(at: file) }
    }
    return target
  }
  // Уменьшает готовый кадр, смягчает границы и сохраняет байты в текстовом виде под строгим
  // пределом. Лента может получить такую картинку вместе с историей.
  static func tiny(normal: URL) throws -> String {
    guard let source = CGImageSourceCreateWithURL(normal as CFURL, nil),
      let small = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 48, kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    else { throw MediaError.corrupt }
    let input = CIImage(cgImage: small),
      filter = input.clampedToExtent().applyingFilter(
        "CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]
      ).cropped(to: input.extent)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    guard let image = context.createCGImage(filter, from: input.extent) else {
      throw MediaError.corrupt
    }
    let data = try jpeg(image, quality: 0.4)
    guard data.count <= 3072 else { throw MediaError.unavailable }
    return data.base64EncodedString()
  }
  // Сжимает одно изображение с указанным качеством и проверяет завершение записи и размер.
  // Слишком большая или неполная копия возвращает ошибку.
  static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
    let bytes = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        bytes, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw MediaError.io }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination), bytes.length <= 256 * 1024 else {
      throw MediaError.io
    }
    return bytes as Data
  }
}
