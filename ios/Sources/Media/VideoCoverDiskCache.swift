// Хранит готовые чёткие кадры видео и небольшие копии для просмотра. Они позволяют вернуться к
// ролику после очистки памяти или удаления скачанного исходника.

import Foundation
import CoreGraphics
import CryptoKit
import Darwin

// Готовые точки возвращают чёткий кадр без повторного чтения сжатого изображения.
final class VideoCoverDiskCache: @unchecked Sendable {
  private static let gate = NSLock()
  private final class WeakCache {
    weak var value: VideoCoverDiskCache?
    // Запоминает хранилище слабой ссылкой. Список живых владельцев нужен для отзыва, но сам
    // список не должен удерживать закрытое хранилище.
    init(_ value: VideoCoverDiskCache) { self.value = value }
  }
  private static var active: [WeakCache] = []
  private let root: URL
  private var closed = false
  private var deletionEpoch: UInt64 = 0
  private let epochGate = NSLock()
  private var revokedPaths: [String] = []
  private static let headerBytes = 88, maximumBytes = 4 * 1024 * 1024
  // Запоминает корень и регистрирует текущего владельца среди живых. При удалении исходника нужно
  // предупредить все открытые хранилища этого аккаунта.
  init(root: URL) {
    self.root = root
    Self.gate.lock()
    Self.active.removeAll { $0.value == nil }
    Self.active.append(WeakCache(self))
    Self.gate.unlock()
  }
  // Читает номер последнего отзыва под блокировкой. Подготовку кадра можно начать сейчас и
  // проверить этот номер перед будущей записью.
  func epoch() -> UInt64 {
    epochGate.lock()
    defer { epochGate.unlock() }
    return deletionEpoch
  }
  // Получает постоянный отпечаток текста для имени файла. Разделители пути не попадают в имя на
  // диске.
  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  // Строит путь к папке кадров и отклоняет путь через ссылку. Иначе чтение или удаление вышло бы
  // за пределы папки владельца.
  private static func directory(_ root: URL) throws -> URL {
    let url = root.appendingPathComponent("media/video-covers")
    guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
      throw MediaError.corrupt
    }
    return url
  }
  // Объединяет отпечаток исходника и ключ конкретного показа. Так можно отозвать все кадры одного
  // файла и различать несколько его появлений в чате.
  private static func name(_ key: VideoPlaybackKey) -> String {
    hash(key.relativePath) + "-" + hash(key.cacheKey) + ".frame"
  }
  // Проверяет отзыв и размеры, записывает описание и пиксели с контрольными суммами. Убирает
  // остатки записи и старые кадры по числу и общему размеру, чтобы полезная копия не росла без
  // предела.
  func store(_ image: CGImage, key: VideoPlaybackKey, epoch: UInt64? = nil) throws {
    Self.gate.lock()
    defer { Self.gate.unlock() }
    guard !closed, epoch == nil || epoch == deletionEpoch,
      !revokedPaths.contains(Self.hash(key.relativePath)), image.bitsPerPixel == 32, image.bitsPerComponent == 8,
      max(image.width, image.height) <= 1024,
      image.bytesPerRow * image.height <= Self.maximumBytes,
      let bytes = image.dataProvider?.data else { return }
    let directory = try Self.directory(root), fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    // Прерванная запись и отметки прежней версии не должны оставаться в папке кадров.
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    where !["frame", "jpg"].contains(file.pathExtension) {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        try fm.removeItem(at: file)
      }
    }
    let payload = bytes as Data
    guard payload.count == image.bytesPerRow * image.height else { return }
    var data = Data("KVIDEO01".utf8)
    for value in [image.width, image.height, image.bytesPerRow, Int(image.bitmapInfo.rawValue)] {
      var word = UInt32(value).littleEndian
      withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: SHA256.hash(data: Data(key.cacheKey.utf8)))
    data.append(contentsOf: SHA256.hash(data: payload))
    data.append(payload)
    try data.write(to: directory.appendingPathComponent(Self.name(key)), options: .atomic)
    let files = try fm.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "frame" }
    let ordered = files.sorted {
      ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }
    var count = files.count
    var size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    for file in ordered where count > 64 || size > 128 * 1024 * 1024 {
      let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      try fm.removeItem(at: file)
      count -= 1
      size -= bytes
    }
  }
  // Находит небольшой чёткий кадр, проверяет, что это обычный файл нужного размера, и отмечает
  // чтение. Удалённый исходник не возвращается из этой копии.
  func galleryFile(_ relative: String) -> URL? {
    Self.gate.lock()
    defer { Self.gate.unlock() }
    let prefix = Self.hash(relative)
    guard !closed, !revokedPaths.contains(prefix),
      let directory = try? Self.directory(root) else { return nil }
    let file = directory.appendingPathComponent(prefix + "-gallery.jpg")
    var info = stat()
    guard file.path.withCString({ lstat($0, &info) }) == 0,
      (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      (1...262_144).contains(info.st_size) else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    return file
  }

  // Проверяет размер и номер отзыва и сохраняет готовую уменьшенную копию целиком. Старые копии
  // убирает по времени, оставляя место новым.
  func storeGalleryFile(_ data: Data, relative: String, epoch: UInt64) throws {
    guard (1...262_144).contains(data.count) else { return }
    Self.gate.lock()
    defer { Self.gate.unlock() }
    let prefix = Self.hash(relative)
    guard !closed, epoch == deletionEpoch, !revokedPaths.contains(prefix) else { return }
    let directory = try Self.directory(root), fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(prefix + "-gallery.jpg")
    guard !fm.fileExists(atPath: file.path) else { return }
    try data.write(to: file, options: .atomic)
    let copies = try fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
      .filter { $0.lastPathComponent.hasSuffix("-gallery.jpg") && $0 != file }
    if copies.count >= 256 {
      let ordered = copies.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast) <
          ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
      }
      for old in ordered.prefix(copies.count - 255) { try fm.removeItem(at: old) }
    }
  }

  // Проверяет файл и резервирует его размер в памяти до чтения, затем сверяет описание и обе
  // контрольные суммы. Рисунок удерживает открытое отображение файла, пока нужен экрану.
  func readPixels(_ key: VideoPlaybackKey, budget: ImageByteBudget) -> ImagePixels? {
    Self.gate.lock()
    defer { Self.gate.unlock() }
    guard !closed, !revokedPaths.contains(Self.hash(key.relativePath)),
      let directory = try? Self.directory(root)
    else { return nil }
    let path = directory.appendingPathComponent(Self.name(key))
    let fd = path.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_size >= Self.headerBytes, info.st_size <= Self.headerBytes + Self.maximumBytes
    else { return nil }
    let count = Int(info.st_size), amount = count - Self.headerBytes
    guard let charge = budget.reserve(amount) else { return nil }
    let pointer = mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, 0)
    guard let pointer, pointer != MAP_FAILED else { charge.close(); return nil }
    let mapped = Data(bytesNoCopy: pointer, count: count,
      deallocator: .custom { pointer, length in munmap(pointer, length) })
    // Читает четыре байта заголовка в согласованном порядке. Так размеры и длина строки
    // восстанавливаются одинаково при записи и чтении.
    func word(_ offset: Int) -> Int {
      Int(UInt32(mapped[offset]) | UInt32(mapped[offset + 1]) << 8
        | UInt32(mapped[offset + 2]) << 16 | UInt32(mapped[offset + 3]) << 24)
    }
    let w = word(8), h = word(12), stride = word(16), bitmap = UInt32(word(20))
    guard mapped.prefix(8) == Data("KVIDEO01".utf8), (1...1024).contains(w),
      (1...1024).contains(h), stride >= w * 4, stride <= 1024 * 4,
      stride * h == amount,
      mapped[24..<56].elementsEqual(SHA256.hash(data: Data(key.cacheKey.utf8))),
      mapped[56..<88].elementsEqual(SHA256.hash(data: mapped[88..<count])) else {
      charge.close(); return nil
    }
    // Провайдер удерживает отображение файла, пока системой рисования используется изображение.
    let holder = Unmanaged.passRetained(mapped as NSData).toOpaque()
    guard let provider = CGDataProvider(dataInfo: holder,
      data: pointer.advanced(by: Self.headerBytes), size: amount,
      releaseData: { info, _, _ in if let info { Unmanaged<NSData>.fromOpaque(info).release() } }),
      let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: bitmap), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
      charge.close(); return nil
    }
    return ImagePixels(image: image, charge: charge)
  }
  // Закрывает запись и чтение, забывает отметки и снимает себя из списка живых владельцев.
  // Следующее удаление не должно планировать работу для закрытой записи.
  func close() {
    Self.gate.lock()
    closed = true
    revokedPaths.removeAll()
    Self.active.removeAll { $0.value == nil || $0.value === self }
    Self.gate.unlock()
  }
  // Меняет номер отзыва у живых хранилищ того же корня и убирает все копии исходника по общему
  // имени. Поздняя подготовка больше не запишет удалённый кадр обратно.
  static func revoke(root: URL, relativePath: String) throws {
    gate.lock()
    defer { gate.unlock() }
    let directory = try directory(root), fm = FileManager.default, prefix = hash(relativePath)
    let identity = root.resolvingSymlinksInPath().standardizedFileURL.path
    active.removeAll { $0.value == nil }
    for item in active {
      guard let cache = item.value,
        cache.root.resolvingSymlinksInPath().standardizedFileURL.path == identity else { continue }
      cache.epochGate.lock()
      cache.deletionEpoch &+= 1
      cache.epochGate.unlock()
      cache.revokedPaths.removeAll { $0 == prefix }
      cache.revokedPaths.append(prefix)
      if cache.revokedPaths.count > 512 { cache.revokedPaths.removeFirst() }
    }
    guard fm.fileExists(atPath: directory.path) else { return }
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix(prefix + "-") { try fm.removeItem(at: file) }
  }
}
