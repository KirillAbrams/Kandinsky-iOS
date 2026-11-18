// Владеет соединением базы и выполняет команды по очереди вне экрана. Здесь открываются таблицы,
// ограничиваются ожидающие запросы и удаляются старые временные копии.

import Foundation
import SQLite3

private final class SQLCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  // Записывает отметку отмены под замком, чтобы очередь могла безопасно прочесть её с другого
  // потока. Команда, которая ещё ждёт, тогда не начнёт работу.
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
  // Читает отметку отмены под тем же замком, чтобы очередь увидела её перед началом работы.
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
final class SQLiteStore: @unchecked Sendable {
  let root: URL
  let faults: RepositoryFaults
  private let queue = DispatchQueue(label: "dev.kirill.kandinsky.sqlite", qos: .userInitiated)
  private var connection: SQLiteConnection?
  // Одна операция выполняется, ещё шестьдесят четыре могут ждать без остановки экрана
  private let admission = DispatchSemaphore(value: 65)
  // Запоминает папку и настройки проверочных сбоев. Соединение откроет отдельная очередь, поэтому
  // создание оболочки не блокирует вызывающий код.
  private init(root: URL, faults: RepositoryFaults) {
    self.root = root
    self.faults = faults
  }
  // Создаёт папку, убирает временные файлы старых запусков, открывает базу и обновляет её
  // таблицы. При сбое закрывает соединение и возвращает ошибку вместо частично открытого
  // хранилища.
  static func open(root: URL, faults: RepositoryFaults = RepositoryFaults()) async throws
    -> SQLiteStore
  {
    let store = SQLiteStore(root: root, faults: faults)
    return try await withCheckedThrowingContinuation { continuation in
      store.queue.async {
        do {
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          try AttachmentScratch.removePreviousRuns(in: root)
          var raw: OpaquePointer?
          let code = sqlite3_open_v2(
            root.appendingPathComponent("chat.sqlite3").path, &raw,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
          guard code == SQLITE_OK, let raw else {
            if let raw { sqlite3_close_v2(raw) }
            throw SQLiteFailure(code: code)
          }
          let db = SQLiteConnection(raw)
          do {
            sqlite3_busy_timeout(raw, 5000)
            try db.execute("PRAGMA foreign_keys=ON")
            try db.execute("PRAGMA journal_mode=WAL")
            try db.execute("PRAGMA synchronous=FULL")
            try SchemaMigrations.apply(db)
            store.connection = db
            continuation.resume(returning: store)
          } catch {
            sqlite3_close_v2(raw)
            throw error
          }
        } catch { continuation.resume(throwing: Self.map(error)) }
      }
    }
  }
  // Пускает работу в ограниченную очередь и перед началом проверяет отмену. Когда работа
  // закончится или будет пропущена, освобождает место для следующей команды.
  func perform<T>(_ action: @escaping (SQLiteConnection) throws -> T) async throws -> T {
    guard admission.wait(timeout: .now()) == .success else { throw RepoError.io }
    let cancellation = SQLCancellation()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          queue.async { [self] in
            defer { admission.signal() }
            guard !cancellation.cancelled, let db = connection else {
              continuation.resume(throwing: RepoError.cancelled)
              return
            }
            do { continuation.resume(returning: try action(db)) } catch {
              continuation.resume(throwing: Self.map(error))
            }
          }
        }
      }, onCancel: { cancellation.cancel() })
  }
  // Ставит закрытие в очередь после принятых команд. Обнуляет соединение после успешного
  // закрытия, поэтому дальнейшая работа не обратится к уже освобождённой базе.
  func close() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        if let db = connection {
          let status = sqlite3_close_v2(db.handle)
          guard status == SQLITE_OK else {
            continuation.resume(throwing: Self.map(SQLiteFailure(code: status)))
            return
          }
          connection = nil
        }
        continuation.resume(returning: ())
      }
    }
  }
  // Превращает сбои базы и отмену задачи в ошибки, понятные остальному приложению. Например,
  // заполненное хранилище можно отличить от повреждённого файла.
  static func map(_ error: Error) -> Error {
    if let e = error as? RepoError { return e }
    if error is CancellationError { return RepoError.cancelled }
    if let e = error as? SQLiteFailure {
      switch e.code & 0xff {
      case SQLITE_FULL: return RepoError.storageFull
      case SQLITE_CORRUPT, SQLITE_NOTADB: return RepoError.corrupt
      case SQLITE_CONSTRAINT: return RepoError.invalidInput
      default: return RepoError.io
      }
    }
    return RepoError.io
  }
  // Ставит освобождение соединения в очередь, если владелец ушёл без явного закрытия. База не
  // останется открытой до завершения процесса.
  deinit { if let db = connection { queue.async { sqlite3_close_v2(db.handle) } } }
}

/// Каждому запуску принадлежит своя папка. После сбоя следующий запуск удаляет оставшиеся копии.
enum AttachmentScratch {
  private static let run = UUID().uuidString
  private static let folder = "attachment-scratch"

  // Убирает каталоги временных вложений, оставшиеся от прежних запусков. Папку текущего запуска
  // сохраняет, чтобы не сорвать ещё идущую подготовку.
  static func removePreviousRuns(in root: URL) throws {
    let parent = root.appendingPathComponent(folder, isDirectory: true)
    let files = FileManager.default
    guard files.fileExists(atPath: parent.path) else { return }
    for entry in try files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
    where entry.lastPathComponent != run {
      try files.removeItem(at: entry)
    }
  }

  // Создаёт защищённую папку текущего запуска и выделяет новое имя с нужным расширением. Разные
  // операции подготовки не перезапишут временную копию друг друга.
  static func file(in root: URL, extension suffix: String) throws -> URL {
    let directory = root.appendingPathComponent(folder).appendingPathComponent(run)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
  }
}
