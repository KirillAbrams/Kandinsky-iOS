import Foundation
import SQLite3

enum SQLValue {
  case null, integer(Int64), real(Double), text(String)
  var int: Int64 {
    if case let .integer(v) = self { return v }
    return 0
  }
  var string: String {
    if case let .text(v) = self { return v }
    return ""
  }
  var optionalInt: Int64? {
    if case let .integer(v) = self { return v }
    return nil
  }
}
typealias SQLRow = [String: SQLValue]
struct SQLiteFailure: Error { let code: Int32 }
private let sqlTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
final class SQLiteConnection {
  let handle: OpaquePointer
  init(_ handle: OpaquePointer) { self.handle = handle }
  private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
    var s: OpaquePointer?
    let code = sqlite3_prepare_v2(handle, sql, -1, &s, nil)
    guard code == SQLITE_OK, let statement = s else {
      if let s { sqlite3_finalize(s) }
      throw SQLiteFailure(code: code)
    }
    do {
      for (i, v) in values.enumerated() {
        let n = Int32(i + 1), status: Int32
        switch v {
        case .null: status = sqlite3_bind_null(statement, n)
        case let .integer(value): status = sqlite3_bind_int64(statement, n, value)
        case let .real(value): status = sqlite3_bind_double(statement, n, value)
        case let .text(value):
          status = value.withCString {
            sqlite3_bind_text(statement, n, $0, Int32(value.utf8.count), sqlTransient)
          }
        }
        guard status == SQLITE_OK else { throw SQLiteFailure(code: status) }
      }
      return statement
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }
  @discardableResult func execute(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
    let s = try prepare(sql, values)
    defer { sqlite3_finalize(s) }
    let status = sqlite3_step(s)
    guard status == SQLITE_DONE || status == SQLITE_ROW else { throw SQLiteFailure(code: status) }
    return sqlite3_last_insert_rowid(handle)
  }
  func forEachRow(_ sql: String, _ values: [SQLValue] = [], _ consume: (SQLRow) throws -> Bool)
    throws
  {
    let s = try prepare(sql, values)
    defer { sqlite3_finalize(s) }
    while true {
      let status = sqlite3_step(s)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw SQLiteFailure(code: status) }
      var row: SQLRow = [:]
      for column in 0..<sqlite3_column_count(s) {
        let key = String(cString: sqlite3_column_name(s, column))
        switch sqlite3_column_type(s, column) {
        case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(s, column))
        case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(s, column))
        case SQLITE_TEXT:
          let length = Int(sqlite3_column_bytes(s, column))
          guard let pointer = sqlite3_column_text(s, column),
            let value = String(data: Data(bytes: pointer, count: length), encoding: .utf8)
          else { throw RepoError.corrupt }
          row[key] = .text(value)
        default: row[key] = .null
        }
      }
      if try !consume(row) { return }
    }
  }
  /// Первую строку сохраняет даже при большом размере, чтобы вызывающая функция могла получить хотя бы
  /// один результат.
  func rows(_ sql: String, _ values: [SQLValue] = [], maxBytes: Int = 8 * 1024 * 1024) throws
    -> [SQLRow]
  {
    var result: [SQLRow] = [], bytes = 0
    try forEachRow(sql, values) { row in
      let cost = row.values.reduce(0) { $0 + $1.string.utf8.count + 24 }
      if !result.isEmpty && bytes + cost > maxBytes { return false }
      result.append(row)
      bytes += cost
      return true
    }
    return result
  }
  func scalar(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
    var value: Int64 = 0
    try forEachRow(sql, values) { row in
      value = row.values.first?.int ?? 0
      return false
    }
    return value
  }
  /// Вызывающая функция получает свой результат только после подтверждения сохранения.
  func transaction<T>(_ action: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try action()
      try execute("COMMIT")
      return result
    } catch {
      if sqlite3_get_autocommit(handle) == 0 { try? execute("ROLLBACK") }
      throw error
    }
  }
}
