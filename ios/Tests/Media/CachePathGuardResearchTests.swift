// Здесь сверяются быстрый и исходный способы находить файлы в каталоге приложения. Проверки
// измеряют работу на обычных именах и следят, чтобы разбор ссылок сохранял границы каталога и
// закрывал открытые файлы.

import XCTest
import Foundation
import Darwin
@testable import Kandinsky

@MainActor final class CachePathGuardResearchTests: XCTestCase {
  // Проверяем относительное имя и приводим каталог и файл к настоящим путям. Эту отдельную
  // способ используем как эталон результата для сравнения с рабочим поиском.
  private nonisolated static func reference(root: URL, relative: String) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard !relative.hasPrefix("/"), !parts.isEmpty, !parts.contains(""), !parts.contains(".."),
      !parts.contains(".")
    else { throw MediaError.corrupt }
    let expected = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(
      "media")
    var info = stat()
    let status = expected.path.withCString { lstat($0, &info) }
    let base: URL
    if status == 0 {
      guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw MediaError.corrupt }
      base = expected
    } else {
      base = expected.resolvingSymlinksInPath().standardizedFileURL
      guard base.path == expected.path else { throw MediaError.corrupt }
    }
    let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else { throw MediaError.corrupt }
    return file
  }
  // Создаём временную структуру с каталогами приложения и отдельным внешним каталогом. Изоляция
  // нужна, чтобы измерения не затрагивали сохранённые файлы пользователя.
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Kandinsky-cache-path-" + UUID().uuidString)
    for name in ["media/remote", "media/previews", "media/objects", "outside"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    return root
  }
  // Читаем подготовленное настоящее фото как байты без повторного сжатия. Один и тот же файл
  // наполняет оба варианта путей.
  private func jpeg() throws -> Data {
    let base = try XCTUnwrap(
      Bundle(for: RepositoryHarness.self).url(forResource: "fixtures", withExtension: nil))
    return try Data(
      contentsOf: base.appendingPathComponent(
        "real-media/backend-824d66cce0d64409ad4888a13792c7d4.jpg"))
  }
  // Возвращаем сумму пользовательского и системного времени текущего потока. Так задержка очереди
  // и нагрузка других потоков меньше влияют на сравнение.
  private nonisolated static func cpu() throws -> Double {
    var info = thread_basic_info_data_t(),
      count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { p in
      p.withMemoryRebound(to: integer_t.self, capacity: capacity) {
        thread_info(
          pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { throw MediaError.unavailable }
    return Double(info.user_time.seconds) + Double(info.system_time.seconds) + Double(
      info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
  }
  // Наполняем обычные каталоги и сверяем, что оба подхода возвращают одинаковые пути. Затем
  // чередуем замеры. Быстрый путь должен заметно уменьшить затраты потока при том же объёме
  // работы.
  func testCachePathsAvoidRepeatedGenericAncestryWalks() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = (1...8).map { index in
      (index % 2 == 0 ? "previews/" : "remote/")
        + String(format: index < 5 ? "%032x" : "%064x", index) + (index == 7 ? "" : ".jpg")
    }
    let bytes = try jpeg()
    for path in paths.prefix(4) {
      try bytes.write(to: root.appendingPathComponent("media/" + path))
    }
    for path in paths {
      XCTAssertEqual(
        try MediaStore.fileURL(root: root, relative: path),
        try Self.reference(root: root, relative: path))
    }
    let queue = DispatchQueue(label: "Kandinsky.test.cache-path", qos: .userInitiated)
    let batches: [[String: Double]] = try await withCheckedThrowingContinuation { reply in
      queue.async {
        do {
          // Повторяем обход одного набора путей выбранным способом и собираем число обработанных
          // знаков вместе со временем. Объём нужен, чтобы сравнение не засчитало пропущенную
          // работу как ускорение.
          func batch(_ candidate: Bool, loops: Int) throws -> [String: Double] {
            let begin = try Self.cpu()
            var characters = 0
            for _ in 0..<loops {
              for path in paths {
                characters += try autoreleasepool {
                  try
                    (candidate
                    ? MediaStore.fileURL(root: root, relative: path)
                    : Self.reference(root: root, relative: path)).path.utf8.count
                }
              }
            }
            return [
              "candidate": candidate ? 1 : 0, "threadCPUSeconds": try Self.cpu() - begin,
              "pathCharacters": Double(characters)
            ]
          }
          _ = try batch(false, loops: 5)
          _ = try batch(true, loops: 5)
          var batches: [[String: Double]] = []
          for candidate in [false, true, true, false, false, true, true, false] {
            batches.append(try batch(candidate, loops: 40))
          }
          guard Set(batches.compactMap { $0["pathCharacters"] }).count == 1 else {
            throw MediaError.corrupt
          }
          reply.resume(returning: batches)
        } catch { reply.resume(throwing: error) }
      }
    }
    // Сортируем четыре замера и берём середину между двумя центральными. Случайный быстрый или
    // медленный прогон не определяет весь результат.
    func median(_ values: [Double]) -> Double {
      let v = values.sorted()
      return (v[1] + v[2]) / 2
    }
    let a = median(batches.filter { $0["candidate"] == 0 }.compactMap { $0["threadCPUSeconds"] }),
      b = median(batches.filter { $0["candidate"] == 1 }.compactMap { $0["threadCPUSeconds"] })
    let report: [String: Any] = [
      "scope":
        """
        Public MediaStore resolver CPU contract against frozen44 path policy; exact output and \
        equalcalls; not whole-appFPS
        """,
      "paths": paths, "batches": batches, "medianCandidateReferenceRatio": b / a
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    let file = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    file.name = "cache-path-guard-cpu-contract"
    file.lifetime = .keepAlways
    add(file)
    print("KANDINSKY_CACHE_PATH_CPU \(String(decoding:data,as:UTF8.self))")
    XCTAssertLessThanOrEqual(
      b / a, 0.55,
      "A proven hot cache path must remove repeated ancestry traversal, not just rename it")
  }
  // Сравниваем ответы для обычных, отсутствующих и меняющихся ссылок. После серии проверяем, что
  // временные открытия закрылись. Отдельно оставляем один открытый каталог, чтобы убедиться, что
  // счётчик замечает утечку.
  func testCanonicalPathsAndLiveAliasesMatchFrozenGuardWithoutDescriptorLeaks() throws {
    let root = try root(), fm = FileManager.default
    defer { try? fm.removeItem(at: root) }
    let name = String(repeating: "a", count: 32) + ".jpg", path = "remote/" + name,
      source = root.appendingPathComponent("media/objects/source.jpg")
    try jpeg().write(to: source)
    try fm.copyItem(at: source, to: root.appendingPathComponent("outside/source.jpg"))
    var checks = 0
    // Вызываем оба способа для одинакового корня и имени. Сравниваем либо полученные адреса, либо
    // причины отказа. Разные исходы означают изменение правил.
    func compare(_ suppliedRoot: URL, _ relative: String) {
      checks += 1
      let old = Result { try Self.reference(root: suppliedRoot, relative: relative) },
        new = Result { try MediaStore.fileURL(root: suppliedRoot, relative: relative) }
      switch (old, new) {
      case let (.success(a), .success(b)): XCTAssertEqual(a, b)
      case let (.failure(a), .failure(b)): XCTAssertEqual(a as? MediaError, b as? MediaError)
      default: XCTFail("Guard behavior changed for \(relative): \(old), \(new)")
      }
    }
    let ordinary = [
      path, "previews/" + String(repeating: "b", count: 64) + ".jpg",
      "remote/" + String(repeating: "c", count: 64), "objects/source.jpg", "seed/missing.jpg",
      "remote/invalid-name.jpg", "remote/" + String(repeating: "D", count: 32) + ".png"
    ]
    for relative in ordinary + [
      "", "/" + path, "../outside/source.jpg", "remote//file.jpg", "remote/../objects/source.jpg",
      "remote/./file.jpg"
    ] { compare(root, relative) }
    let leaf = root.appendingPathComponent("media/" + path)
    try fm.createSymbolicLink(at: leaf, withDestinationURL: source)
    compare(root, path)
    try fm.removeItem(at: leaf)
    try fm.createSymbolicLink(
      at: leaf, withDestinationURL: root.appendingPathComponent("outside/source.jpg"))
    compare(root, path)
    XCTAssertThrowsError(try MediaStore.fileURL(root: root, relative: path)) {
      XCTAssertEqual($0 as? MediaError, .corrupt)
    }
    try fm.removeItem(at: leaf)
    let remote = root.appendingPathComponent("media/remote"),
      held = root.appendingPathComponent("media/remote-held")
    try fm.moveItem(at: remote, to: held)
    try fm.createSymbolicLink(
      at: remote, withDestinationURL: root.appendingPathComponent("media/objects"))
    compare(root, path)
    compare(root, "remote/source.jpg")
    try fm.removeItem(at: remote)
    try fm.createSymbolicLink(
      at: remote, withDestinationURL: root.appendingPathComponent("outside"))
    compare(root, "remote/source.jpg")
    compare(root, path)
    try fm.removeItem(at: remote)
    try fm.moveItem(at: held, to: remote)
    let media = root.appendingPathComponent("media"),
      kept = root.appendingPathComponent("media-held")
    try fm.moveItem(at: media, to: kept)
    try fm.createSymbolicLink(at: media, withDestinationURL: kept)
    compare(root, path)
    XCTAssertThrowsError(try MediaStore.fileURL(root: root, relative: path)) {
      XCTAssertEqual($0 as? MediaError, .corrupt)
    }
    try fm.removeItem(at: media)
    try fm.moveItem(at: kept, to: media)
    let alias = root.deletingLastPathComponent().appendingPathComponent(
      "Kandinsky-root-alias-" + UUID().uuidString)
    try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    defer { try? fm.removeItem(at: alias) }
    for path in ordinary { compare(alias, path) }
    if root.path.hasPrefix("/private/var/") {
      let alias = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)))
      for path in ordinary { compare(alias, path) }
    }
    let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
    // Собираем открытые системные номера путей под временным корнем. Сортировка позволяет
    // сравнить состояние до и после независимо от порядка обхода.
    func descriptors() -> [String] {
      var result: [String] = []
      for fd in 0..<1024 {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = bytes.withUnsafeMutableBytes { fcntl(Int32(fd), F_GETPATH, $0.baseAddress!) }
        if status == 0 {
          let path = URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL.path
          if path == canonical || path.hasPrefix(canonical + "/") { result.append(path) }
        }
      }
      return result.sorted()
    }
    let before = descriptors()
    let heldDescriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
    XCTAssertGreaterThanOrEqual(heldDescriptor, 0)
    if heldDescriptor >= 0 {
      XCTAssertEqual(
        descriptors().count, before.count + 1,
        "The ownership oracle must detect an intentionally held directory descriptor, including the system /var alias"
      )
      Darwin.close(heldDescriptor)
    }
    for _ in 0..<300 { for relative in ordinary { compare(root, relative) } }
    XCTAssertEqual(
      descriptors(), before,
      "Each positive, missing and fallback resolution must retire every temporary descriptor")
    print(
      """
      KANDINSKY_CACHE_PATH_DIFFERENTIAL checks=\(checks) ownedDescriptorsBefore=\(before.count) \
      ownedDescriptorsAfter=\(descriptors().count)
      """
    )
  }
}
