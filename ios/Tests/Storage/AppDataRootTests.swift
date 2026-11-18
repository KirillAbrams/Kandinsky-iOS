// Проверяет перенос папки айфона и открытие уже существующей базы аккаунта на изолированных
// файлах.

import Foundation
import XCTest
@testable import Kandinsky

final class AppDataRootTests: XCTestCase {
  // Создаёт отдельную папку для проверки и убирает её после завершения, даже если проверка упала.
  // Следующий сценарий начинает с чистого места.
  private func withFolder(_ action: (URL) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try action(base)
  }

  // Собирает прежнее хранилище с условной базой, незавершённой записью и оригиналом. Так можно
  // отличить перенос всей папки от переноса одного файла.
  private func previous(_ base: URL, name: String) throws -> URL {
    let root = base.appendingPathComponent(name)
    let user = root.appendingPathComponent("net-v1-u42")
    try FileManager.default.createDirectory(
      at: user.appendingPathComponent("media/objects"), withIntermediateDirectories: true)
    try Data("История и место чтения".utf8).write(to: user.appendingPathComponent("chat.sqlite3"))
    try Data("Незавершённая запись".utf8).write(to: user.appendingPathComponent("chat.sqlite3-wal"))
    try Data([0, 17, 128, 255]).write(to: user.appendingPathComponent("media/objects/original.jpg"))
    return root
  }

  // Сравнивает содержимое всех трёх файлов после переноса и снова открывает ту же папку. Ловит
  // потерю оригинала или незавершённой записи при обновлении.
  func testExistingDataMovesAsOneDirectoryAndRepeatKeepsIt() throws {
    try withFolder { base in
      let old = try previous(base, name: "PreviousNative")
      let target = try AppDataRoot.resolve(base)
      XCTAssertEqual(target.lastPathComponent, "Kandinsky")
      XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent("net-v1-u42/chat.sqlite3")),
        Data("История и место чтения".utf8))
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent("net-v1-u42/chat.sqlite3-wal")),
        Data("Незавершённая запись".utf8))
      XCTAssertEqual(
        try Data(
          contentsOf: target.appendingPathComponent("net-v1-u42/media/objects/original.jpg")),
        Data([0, 17, 128, 255]))
      XCTAssertEqual(try AppDataRoot.resolve(base), target)
    }
  }

  // Готовит две похожие старые папки и проверяет отказ без удаления любой из них. Это защищает
  // историю при неоднозначном выборе.
  func testAmbiguousRootsRemainUntouched() throws {
    try withFolder { base in
      let first = try previous(base, name: "FirstNative")
      let second = try previous(base, name: "SecondNative")
      XCTAssertThrowsError(try AppDataRoot.resolve(base))
      XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
      XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
  }

  // Проверяет перенос отметки удаления аккаунта, когда базы уже нет. Без этого начатая очистка
  // могла бы потеряться при обновлении.
  func testPendingErasureMovesWithoutRemainingDatabase() throws {
    try withFolder { base in
      let old = base.appendingPathComponent("PreviousNative", isDirectory: true)
      let queue = old.appendingPathComponent("erased-accounts", isDirectory: true)
      try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
      try Data().write(to: queue.appendingPathComponent("42"))
      let target = try AppDataRoot.resolve(base)
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent("erased-accounts/42")), Data())
      XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
  }

  // Создаёт готовую и старую папки рядом. Проверяет, что используется готовая, а старая остаётся
  // на месте.
  func testExistingCurrentRootIsNeverOverwritten() throws {
    try withFolder { base in
      let current = try previous(base, name: "Kandinsky")
      let old = try previous(base, name: "PreviousNative")
      XCTAssertEqual(try AppDataRoot.resolve(base).path, current.path)
      XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }
  }

  // Подкладывает ссылку на чужую папку и проверяет, что она не вошла в новое хранилище. Без
  // проверки можно случайно перенести сторонние файлы.
  func testDirectorySymlinkIsNotAnUpgradeSource() throws {
    try withFolder { base in
      try withFolder { external in
        let old = try previous(external, name: "OtherNative")
        try FileManager.default.createSymbolicLink(
          at: base.appendingPathComponent("Alias"), withDestinationURL: old)
        let target = try AppDataRoot.resolve(base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: target.appendingPathComponent("net-v1-u42").path))
      }
    }
  }

  // Пишет условную строку заранее и проверяет, что запуск аккаунта нашёл её в той же папке.
  // Дополнительно сверяет создание и освобождение служб вложений.
  @MainActor func testAccountRuntimeReopensTheExistingAccountDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accountFolder = root.appendingPathComponent("net-v1-u42")
    let existing = try await SQLiteStore.open(root: accountFolder)
    try await existing.perform { db in
      try db.execute("CREATE TABLE runtime_fixture (value INTEGER NOT NULL)")
      try db.execute("INSERT INTO runtime_fixture VALUES (42)")
    }
    try await existing.close()

    let profile = NetworkProfile(
      userId: 42, deviceId: UUID().uuidString, name: "Local fixture",
      token: String(repeating: "a", count: 64), expiresAtMs: Int64.max)
    let runtime = try await AccountRuntime.open(root: root, profile: profile)
    XCTAssertEqual(runtime.store.root.path, accountFolder.path)
    let value = try await runtime.store.perform { db in
      try db.scalar("SELECT value FROM runtime_fixture")
    }
    XCTAssertEqual(value, 42)
    let admission = MediaAdmission()
    try await runtime.prepareMedia(admission: admission)
    XCTAssertNotNil(runtime.media)
    XCTAssertNotNil(runtime.playback)
    runtime.closeServices()
    XCTAssertNil(runtime.media)
    XCTAssertNil(runtime.playback)
    admission.close()
    try await runtime.store.close()
  }
}
