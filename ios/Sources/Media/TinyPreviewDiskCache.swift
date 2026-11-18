import Foundation
import Accelerate
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

/// Хранит готовые пиксели маленьких изображений на диске без повторного сжатия.
enum TinyPreviewDiskCache {
  private static let gate = NSLock()
  private static let buckets = 4000, headerSize = 72, maximumRecord = 72 + 64 * 64 * 4
  // Новая версия фильтра заменяет прежние пиксели при следующем чтении.
  private static let recordMagic: [UInt8] = [0x57, 0x54, 0x49, 0x33]
  private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

  static func image(_ data: Data, root: URL, video: Bool = false) throws -> CGImage {
    precondition(!Thread.isMainThread)
    guard data.count <= 3072 else { throw MediaError.corrupt }
    gate.lock()
    defer { gate.unlock() }
    var hash = SHA256()
    if video { hash.update(data: Data("video-blur:".utf8)) }
    hash.update(data: data)
    let key = Data(hash.finalize()), bucket = (Int(key[0]) * 256 + Int(key[1])) % buckets
    let name = String(format: "%04x.rgba", bucket), directory = openDirectory(root)
    defer { if directory >= 0 { Darwin.close(directory) } }
    if directory >= 0, let record = read(name, directory: directory),
      let image = restore(record, key: key)
    {
      return image
    }
    let image = try prepare(data, video: video)
    if directory >= 0, let record = record(image, key: key) {
      write(record, name: name, directory: directory)
    }
    return image
  }
  private static func openDirectory(_ root: URL) -> Int32 {
    guard root.isFileURL, (root.host ?? "").isEmpty else { return -1 }
    let profile = root.path.withCString { Darwin.open($0, directoryFlags) }
    guard profile >= 0 else { return -1 }
    defer { Darwin.close(profile) }
    let media = openChildDirectory("media", parent: profile)
    guard media >= 0 else { return -1 }
    defer { Darwin.close(media) }
    return openChildDirectory("tiny", parent: media)
  }
  private static func openChildDirectory(_ name: String, parent: Int32) -> Int32 {
    name.withCString { path in
      let existing = Darwin.openat(parent, path, directoryFlags)
      if existing >= 0 { return existing }
      guard errno == ENOENT, Darwin.mkdirat(parent, path, 0o700) == 0 || errno == EEXIST else {
        return -1
      }
      return Darwin.openat(parent, path, directoryFlags)
    }
  }
  static func prepare(_ data: Data, video: Bool = false) throws -> CGImage {
    guard data.count <= 3072,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...64).contains(width), (1...64).contains(height),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    else { throw MediaError.corrupt }
    return try softened(image, video: video)
  }

  private static func softened(_ image: CGImage, video: Bool) throws -> CGImage {
    let width = image.width, height = image.height
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw MediaError.io }
    func raster() -> CGContext? {
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    guard let source = raster(), let destination = raster(),
      let sourceBytes = source.data, let destinationBytes = destination.data
    else { throw MediaError.unavailable }
    source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var input = vImage_Buffer(
      data: sourceBytes, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: source.bytesPerRow)
    var output = vImage_Buffer(
      data: destinationBytes, height: vImagePixelCount(height), width: vImagePixelCount(width),
      rowBytes: destination.bytesPerRow)
    // Два прохода сглаживают границы пикселей до увеличения миниатюры на экране.
    let radius = max(2, (max(width, height) + 4) / (video ? 4 : 5))
    let kernelHeight = UInt32(2 * min(radius, (height - 1) / 2) + 1)
    let kernelWidth = UInt32(2 * min(radius, (width - 1) / 2) + 1)
    let flags = vImage_Flags(kvImageEdgeExtend)
    let status = withExtendedLifetime(destination) {
      let firstPass = vImageTentConvolve_ARGB8888(
        &input, &output, nil, 0, 0, kernelHeight, kernelWidth, nil, flags)
      guard firstPass == kvImageNoError else { return firstPass }
      return vImageTentConvolve_ARGB8888(
        &output, &input, nil, 0, 0, kernelHeight, kernelWidth, nil, flags)
    }
    guard status == kvImageNoError, let result = source.makeImage() else {
      throw MediaError.io
    }
    return result
  }
  /// Отдельно вычисляет отпечаток записанного рисунка, чтобы последующее чтение могло заметить повреждение.
  private static func record(_ image: CGImage, key: Data) -> Data? {
    let width = image.width, height = image.height
    guard (1...64).contains(width), (1...64).contains(height) else { return nil }
    var data = Data(count: headerSize + width * height * 4)
    data.replaceSubrange(0..<4, with: recordMagic)
    data.replaceSubrange(4..<8, with: [UInt8(width), UInt8(height), 1, 0])
    data.replaceSubrange(8..<40, with: key)
    let rendered = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
      guard let base = bytes.baseAddress, let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: base.advanced(by: headerSize), width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      var hash = SHA256()
      hash.update(
        bufferPointer: UnsafeRawBufferPointer(
          start: base.advanced(by: headerSize), count: width * height * 4))
      let digest = Array(hash.finalize())
      digest.withUnsafeBytes {
        base.advanced(by: 40).copyMemory(from: $0.baseAddress!, byteCount: 32)
      }
      return true
    }
    return rendered ? data : nil
  }
  private static func restore(_ record: Data, key: Data) -> CGImage? {
    guard (headerSize...maximumRecord).contains(record.count),
      Array(record.prefix(4)) == recordMagic, record[6] == 1, record[7] == 0,
      record.subdata(in: 8..<40) == key
    else { return nil }
    let width = Int(record[4]), height = Int(record[5])
    guard (1...64).contains(width), (1...64).contains(height),
      record.count == headerSize + width * height * 4
    else { return nil }
    let payload = record.subdata(in: headerSize..<record.count)
    guard Data(SHA256.hash(data: payload)) == record.subdata(in: 40..<72),
      let provider = CGDataProvider(data: payload as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
  private static func read(_ name: String, directory: Int32) -> Data? {
    let fd = name.withCString {
      Darwin.openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var info = stat()
    guard Darwin.fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_size >= headerSize, info.st_size <= maximumRecord
    else { return nil }
    var data = Data(count: Int(info.st_size))
    let complete = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    return complete ? data : nil
  }
  /// Только после полной записи заменяет целевую ячейку, чтобы читатель не получил половину нового рисунка.
  private static func write(_ data: Data, name: String, directory: Int32) {
    // One fixed pending file also bounds leftovers after a crash. The process-wide
    // gate serializes writers, including two MediaStores retiring the same profile.
    _ = Darwin.unlinkat(directory, "pending.rgba", 0)
    let fd = Darwin.openat(
      directory, "pending.rgba", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return }
    defer {
      Darwin.close(fd)
      _ = Darwin.unlinkat(directory, "pending.rgba", 0)
    }
    let complete = data.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
    if complete {
      _ = name.withCString { Darwin.renameat(directory, "pending.rgba", directory, $0) }
    }
  }
}
