// Проверяет маленькие размытые изображения, которые хранятся готовыми на диске. Сверяет их
// пиксели, ограничение места и обработку повреждённых записей.

import XCTest
import UIKit
import CryptoKit
import ImageIO
import Darwin
@testable import Kandinsky

@MainActor final class TinyPreviewDiskCacheTests: XCTestCase {
  private struct Input: Decodable { let records: [Record] }
  private struct Record: Decodable { let tinyPreview: String }
  // Читает первую настоящую миниатюру из сохранённого набора и восстанавливает её байты. Проверки
  // используют то же представление, которое приходит вместе с историей.
  private func input() throws -> Data {
    let file = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/tiny-preview-probe.json")
    let records = try JSONDecoder().decode(Input.self, from: Data(contentsOf: file)).records
    return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(records.first).tinyPreview))
  }
  // Делает описание фотографии или ролика с переданными байтами миниатюры. Вид вложения позволяет
  // проверить два разных правила сглаживания.
  private func attachment(_ data: Data, video: Bool = false) -> Attachment {
    Attachment(
      id: "tiny-cache-probe",
      relativePath: "remote/00000000000000000000000000000001." + (video ? "mp4" : "jpg"),
      mime: video ? "video/mp4" : "image/jpeg", byteSize: 10000, rawWidth: 1200, rawHeight: 800, orientation: 1,
      durationMs: nil, thumbnailKey: "", tinyPreview: data.base64EncodedString())
  }
  // Запрашивает малую картинку через обычное хранилище и ждёт его ответа. Проверка проходит тот
  // же путь, что и экран.
  private func preview(_ data: Data, media: MediaStore, video: Bool = false) async throws
    -> PreparedImage
  {
    try await withCheckedThrowingContinuation { reply in
      _ = media.tinyPreview(attachment(data, video: video)) { reply.resume(with: $0) }
    }
  }
  // Рисует изображение в известном порядке цветов и возвращает его байты. Так можно сравнивать
  // сами пиксели, даже если рисунки создавались разными способами.
  private func pixels(_ image: CGImage) throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
  }
  /// Разные исходники могут попасть в одну ячейку, поэтому запись отдельно проверяет полный отпечаток.
  // Повторяет расчёт номера ячейки от полного отпечатка. Зная путь, проверка может подставить
  // неправильную запись или найти два входа для одной ячейки.
  private func cachedFile(_ data: Data, root: URL) -> URL {
    let key = Array(SHA256.hash(data: data)), bucket = (Int(key[0]) * 256 + Int(key[1])) % 4000
    return root.appendingPathComponent(String(format: "media/tiny/%04x.rgba", bucket))
  }
  // Сравнивает одиннадцать исходных маленьких картинок с обработанными. Сверяет снижение резких
  // перепадов и сохранение размеров и средней яркости, чтобы увидеть сглаживание без смены
  // исходника.
  func testLegacyInlineJPEGsDisplaySoftGradients() async throws {
    let h = try await RepositoryHarness.open()
    let media = MediaStore(store: h.store)
    defer { media.close() }
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/tiny-preview-probe.json")
    let records = try JSONDecoder().decode(Input.self, from: Data(contentsOf: fixture)).records
    XCTAssertEqual(records.count, 11)

    // Переводит три цветовых составляющих в взвешенную яркость. Так перепады можно сравнить одним
    // рядом значений.
    func luminance(_ image: CGImage) throws -> [Int] {
      let bytes = Array(try pixels(image))
      return stride(from: 0, to: bytes.count, by: 4).map {
        (3 * Int(bytes[$0]) + 6 * Int(bytes[$0 + 1]) + Int(bytes[$0 + 2])) / 10
      }
    }
    // Считает отклонения яркости от двух соседей по каждой оси. Резкая ступень даёт большой
    // вклад, плавный переход даёт малый.
    func curvature(_ data: [Int], width: Int, height: Int) -> Int {
      var total = 0
      for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
          let i = y * width + x, center = 2 * data[i]
          total += abs(data[i - 1] + data[i + 1] - center)
          total += abs(data[i - width] + data[i + width] - center)
        }
      }
      return total
    }

    // Складывает квадраты перепадов между соседними точками. Большие перепады влияют сильнее,
    // поэтому сравнение показывает, что размытие приглушило резкие границы.
    func energy(_ data: [Int], width: Int, height: Int) -> Int {
      var total = 0
      for y in 0..<(height - 1) {
        for x in 0..<(width - 1) {
          let i = y * width + x
          let dx = data[i + 1] - data[i], dy = data[i + width] - data[i]
          total += dx * dx + dy * dy
        }
      }
      return total
    }

    for video in [false, true] {
      var worstRatio = 0.0
      var energyRatios: [Double] = []
      for record in records {
        let data = try XCTUnwrap(Data(base64Encoded: record.tinyPreview))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let prepared = try await preview(data, media: media, video: video)
        defer { prepared.close() }
        let image = try XCTUnwrap(prepared.image)
        XCTAssertTrue(prepared.isTinyPreview)
        XCTAssertEqual(image.width, raw.width)
        XCTAssertEqual(image.height, raw.height)
        let before = try luminance(raw), after = try luminance(image)
        let originalCurvature = curvature(before, width: raw.width, height: raw.height)
        let displayCurvature = curvature(after, width: image.width, height: image.height)
        XCTAssertGreaterThan(originalCurvature, 0)
        let ratio = Double(displayCurvature) / Double(originalCurvature)
        worstRatio = max(worstRatio, ratio)
        let inputEnergy = energy(before, width: raw.width, height: raw.height)
        XCTAssertGreaterThan(inputEnergy, 0)
        energyRatios.append(Double(energy(after, width: image.width, height: image.height))
          / Double(inputEnergy))
        XCTAssertLessThanOrEqual(ratio, 0.55, "The old JPEG's pixel steps must soften before scaling")
        XCTAssertLessThanOrEqual(abs(before.reduce(0, +) - after.reduce(0, +)), before.count * 6)
      }
      let median = energyRatios.sorted()[energyRatios.count / 2]
      print("KANDINSKY_SOFT_PREVIEW video=\(video) median_energy=\(median) worst_curvature=\(worstRatio)")
      XCTAssertLessThanOrEqual(median, video ? 0.025 : 0.045,
        "Fine contrast in the incoming placeholder must be lower than before")
    }
    media.close()
    try await h.close()
  }

  // Сохраняет настоящий малый кадр, закрывает его и проверяет нулевой расход памяти. Сверяет поля
  // и пиксели на диске и получает те же байты при повторном открытии.
  func testRealTinyPreviewPersistsLosslessPixelsWithoutRetainingDecodedRAM() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), data = try input()
    defer { media.close() }
    let first = try await preview(data, media: media), firstImage = try XCTUnwrap(first.image),
      expected = try pixels(firstImage)
    first.close()
    XCTAssertEqual(media.bytesUsed, 0, "A disk cache cannot retain a decoded RAM owner")
    let file = cachedFile(data, root: h.root)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: file.path),
      "Persist the already decoded tiny pixels for a later binding instead of JPEG decoding again")
    guard FileManager.default.fileExists(atPath: file.path) else {
      media.close()
      try await h.close()
      return
    }
    let record = try Data(contentsOf: file), key = Data(SHA256.hash(data: data))
    XCTAssertEqual(Array(record.prefix(4)), [0x57, 0x54, 0x49, 0x33])
    XCTAssertEqual(record.count, 72 + expected.count)
    XCTAssertEqual(record.subdata(in: 8..<40), key)
    XCTAssertEqual(record.subdata(in: 40..<72), Data(SHA256.hash(data: expected)))
    XCTAssertEqual(record.dropFirst(72), expected)
    let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    media.close()
    let reopened = MediaStore(store: h.store)
    let second = try await preview(data, media: reopened)
    XCTAssertEqual(try pixels(XCTUnwrap(second.image)), expected)
    second.close()
    XCTAssertEqual(
      try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
      modified, "A verified hit must not decode/rewrite the cached pixels")
    XCTAssertEqual(reopened.bytesUsed, 0)
    reopened.close()
    try await h.close()
  }
  // Подставляет повреждённые записи, неверный вход и лишние байты, затем запрашивает исходную
  // миниатюру. Каждый раз получает правильные пиксели и восстановленную запись допустимого
  // размера.
  func testDamagedOversizedAndWrongInputRecordsFallBackToRealJPEG() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), data = try input()
    defer { media.close() }
    let initial = try await preview(data, media: media),
      expected = try pixels(XCTUnwrap(initial.image))
    initial.close()
    let file = cachedFile(data, root: h.root), valid = try Data(contentsOf: file)
    var obsolete = valid
    obsolete[3] = 0x32
    var variants = [Data(), Data(valid.prefix(20)), valid + Data([0]), obsolete]
    for index in [0, 4, 5, 6, 7, 8, 40, 72] {
      var bad = valid
      bad[index] ^= 0xff
      variants.append(bad)
    }
    for bad in variants {
      try bad.write(to: file)
      let frame = try await preview(data, media: media)
      XCTAssertEqual(try pixels(XCTUnwrap(frame.image)), expected)
      frame.close()
      XCTAssertEqual(media.bytesUsed, 0)
      XCTAssertEqual(
        try Data(contentsOf: file), valid,
        "Corrupt input must be replaced by independently verified pixels")
    }
    let oversized = try FileHandle(forWritingTo: file)
    try oversized.truncate(atOffset: 128 * 1024 * 1024)
    try oversized.close()
    let frame = try await preview(data, media: media)
    XCTAssertEqual(try pixels(XCTUnwrap(frame.image)), expected)
    frame.close()
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    XCTAssertEqual(size, valid.count)
    if size == valid.count { XCTAssertEqual(try Data(contentsOf: file), valid) }
    XCTAssertEqual(media.bytesUsed, 0)
    media.close()
    try await h.close()
  }
  // Подставляет ссылки на чужой файл из временной папки и запрашивает миниатюру. Правильная
  // картинка остаётся доступной, а внешний контрольный файл не читается как картинка и сохраняет
  // байты.
  func testDirectoryAndLeafAliasesCannotExposeOrOverwriteAnotherProfile() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), data = try input()
    let other = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tiny-other-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
      media.close()
      try? FileManager.default.removeItem(at: other)
    }
    let external = other.appendingPathComponent(cachedFile(data, root: h.root).lastPathComponent),
      canary = Data("another profile original; preserve".utf8)
    try canary.write(to: external)
    let directory = h.root.appendingPathComponent("media/tiny")
    try FileManager.default.createDirectory(
      at: h.root.appendingPathComponent("media"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: other)
    let first = try await preview(data, media: media), expected = try pixels(XCTUnwrap(first.image))
    first.close()
    XCTAssertEqual(try Data(contentsOf: external), canary)
    XCTAssertEqual(media.bytesUsed, 0)
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = cachedFile(data, root: h.root)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("pending.rgba"), withDestinationURL: external)
    let second = try await preview(data, media: media)
    XCTAssertEqual(try pixels(XCTUnwrap(second.image)), expected)
    second.close()
    XCTAssertEqual(try Data(contentsOf: external), canary)
    XCTAssertFalse(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending.rgba").path))
    // Папка с предусмотренным временным именем делает запись сохранённого кадра недоступной
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("pending.rgba"), withIntermediateDirectories: true)
    let fallback = try await preview(data, media: media)
    XCTAssertEqual(try pixels(XCTUnwrap(fallback.image)), expected)
    fallback.close()
    XCTAssertEqual(media.bytesUsed, 0)
    XCTAssertEqual(try Data(contentsOf: external), canary)
    media.close()
    try await h.close()
  }
  // Готовит один и тот же вход как фото и видео. Размеры должны совпасть, а у ролика сумма
  // горизонтальных перепадов должна стать меньше.
  func testVideoPlaceholderSmoothsMoreWithoutIncreasingPixelStorage() throws {
    let input = try input()
    let photo = try TinyPreviewDiskCache.prepare(input)
    let video = try TinyPreviewDiskCache.prepare(input, video: true)
    XCTAssertEqual(photo.width, video.width)
    XCTAssertEqual(photo.height, video.height)
    // Складывает отличия цветовых составляющих между соседями по строке. Меньшее число указывает
    // на более мягкие переходы.
    func horizontalEdges(_ image: CGImage) throws -> Int {
      let colors = [UInt8](try pixels(image))
      var total = 0
      for y in 0..<image.height {
        for x in 1..<image.width {
          let pixel = (y * image.width + x) * 4
          for channel in 0..<3 {
            total += abs(Int(colors[pixel + channel]) - Int(colors[pixel - 4 + channel]))
          }
        }
      }
      return total
    }
    let originalEdges = try horizontalEdges(photo)
    let softenedEdges = try horizontalEdges(video)
    XCTAssertLessThan(softenedEdges, originalEdges)
  }

  // Подбирает два разных исходника для одной дисковой ячейки и читает их по очереди. Каждый
  // возвращает свои пиксели, иначе совпавший номер ячейки показывал бы чужой кадр.
  func testFixedBucketCollisionReplacesTheRightPixelsAndInputIdentity() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), first = try input()
    defer { media.close() }
    let fixture = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil)
    ).appendingPathComponent("real-media/tiny-preview-probe.json")
    let records = try JSONDecoder().decode(Input.self, from: Data(contentsOf: fixture)).records
    let source = try XCTUnwrap(Data(base64Encoded: records[1].tinyPreview)),
      wanted = cachedFile(first, root: h.root).lastPathComponent
    var collision: Data?
    for number in UInt32(0)..<100_000 {
      var data = source, nonce = number.littleEndian
      withUnsafeBytes(of: &nonce) { data.append(contentsOf: $0) }
      if cachedFile(data, root: h.root).lastPathComponent == wanted {
        collision = data
        break
      }
    }
    let second = try XCTUnwrap(collision)
    XCTAssertLessThanOrEqual(second.count, 3072)
    let a = try await preview(first, media: media), aPixels = try pixels(XCTUnwrap(a.image))
    a.close()
    let expected = try pixels(TinyPreviewDiskCache.prepare(source))
    XCTAssertNotEqual(expected, aPixels, "Use two different real source images for the collision")
    let b = try await preview(second, media: media)
    XCTAssertEqual(try pixels(XCTUnwrap(b.image)), expected)
    b.close()
    XCTAssertEqual(
      try Data(contentsOf: cachedFile(first, root: h.root)).subdata(in: 8..<40),
      Data(SHA256.hash(data: second)))
    let again = try await preview(first, media: media)
    XCTAssertEqual(try pixels(XCTUnwrap(again.image)), aPixels)
    again.close()
    XCTAssertEqual(
      try Data(contentsOf: cachedFile(first, root: h.root)).subdata(in: 8..<40),
      Data(SHA256.hash(data: first)))
    XCTAssertEqual(media.bytesUsed, 0)
    media.close()
    try await h.close()
  }
  // Подставляет ссылку вместо папки медиа или самого профиля. Используется маленькая картинка из
  // истории, а рядом с внешним файлом не появляется хранилище.
  func testMediaAndProfileAliasesUseJPEGWithoutCreatingAnExternalCache() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), data = try input()
    let
      other = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tiny-ancestor-" + UUID().uuidString, isDirectory: true),
      alias = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tiny-root-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
      media.close()
      try? FileManager.default.removeItem(at: alias)
      try? FileManager.default.removeItem(at: other)
    }
    let canary = other.appendingPathComponent("keep.txt"),
      expected = Data("other profile; preserve".utf8)
    try expected.write(to: canary)
    try FileManager.default.createSymbolicLink(
      at: h.root.appendingPathComponent("media"), withDestinationURL: other)
    let frame = try await preview(data, media: media), image = try XCTUnwrap(frame.image),
      width = image.width, height = image.height
    frame.close()
    XCTAssertEqual(try Data(contentsOf: canary), expected)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: other.appendingPathComponent("tiny").path))
    XCTAssertEqual(media.bytesUsed, 0)
    try FileManager.default.removeItem(at: h.root.appendingPathComponent("media"))
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: h.root)
    let result: Bool = await withCheckedContinuation { reply in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let image = try TinyPreviewDiskCache.image(data, root: alias)
          reply.resume(returning: image.width == width && image.height == height)
        } catch { reply.resume(returning: false) }
      }
    }
    XCTAssertTrue(result)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: h.root.appendingPathComponent("media").path),
      "No writes through an aliased profile root")
    XCTAssertEqual(try Data(contentsOf: canary), expected)
    media.close()
    try await h.close()
  }
  /// Ни один файловый дескриптор не должен оставаться после завершённой подготовки.
  // Подтверждает, что счётчик видит пробный открытый файл, затем обрабатывает много записей.
  // Сверяет ограниченный набор имён и размеров и отсутствие оставшихся открытых файлов.
  func testOwnedDiskNamesHaveAFiniteBoundAndDescriptorsRetire() async throws {
    let h = try await RepositoryHarness.open(),
      media = MediaStore(store: h.store), source = try input()
    defer { media.close() }
    // Считает открытые файловые записи, ведущие в эту временную папку. Разность до и после
    // показывает, осталась ли незакрытая работа.
    func ownedFDs() -> Int {
      var count = 0
      for descriptor in Int32(0)..<Int32(getdtablesize()) {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if path.withUnsafeMutableBytes({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0,
          String(cString: path).contains("/" + h.root.lastPathComponent)
        {
          count += 1
        }
      }
      return count
    }
    let before = ownedFDs()
    let held = h.root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
    XCTAssertGreaterThanOrEqual(held, 0)
    if held >= 0 {
      XCTAssertEqual(ownedFDs(), before + 1)
      Darwin.close(held)
    }
    for number in UInt32(0)..<96 {
      var data = source, nonce = number.littleEndian
      withUnsafeBytes(of: &nonce) { data.append(contentsOf: $0) }
      let frame = try await preview(data, media: media)
      XCTAssertNotNil(frame.image)
      frame.close()
      XCTAssertEqual(media.bytesUsed, 0)
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: h.root.appendingPathComponent("media/tiny"), includingPropertiesForKeys: [.fileSizeKey])
    XCTAssertFalse(files.isEmpty)
    for file in files {
      let stem = file.deletingPathExtension().lastPathComponent
      XCTAssertEqual(file.pathExtension, "rgba")
      XCTAssertEqual(stem.count, 4)
      let slot = try XCTUnwrap(Int(stem, radix: 16))
      XCTAssertTrue((0..<4000).contains(slot))
      XCTAssertLessThanOrEqual(
        try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 72 + 64 * 64 * 4)
    }
    XCTAssertLessThanOrEqual(files.count, 4000)
    XCTAssertLessThan((4000 + 1) * (72 + 64 * 64 * 4), 64 * 1024 * 1024)
    XCTAssertEqual(ownedFDs(), before, "No cache descriptor may survive a finished request")
    media.close()
    try await h.close()
  }
}
