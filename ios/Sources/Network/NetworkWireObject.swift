import CoreFoundation
import Foundation

// Разбор и сохранение выполняются в рабочей очереди базы, вне отрисовки экрана
struct WireObject {
  let value: [String: Any]
  init(_ value: Any) throws {
    guard let object = value as? [String: Any] else { throw RepoError.corrupt }
    self.value = object
  }
  init(data: Data) throws { try self.init(JSONSerialization.jsonObject(with: data)) }
  func int(_ key: String) throws -> Int64 {
    guard let number = value[key] as? NSNumber else { throw RepoError.corrupt }
    return number.int64Value
  }
  func string(_ key: String) throws -> String {
    guard let text = value[key] as? String else { throw RepoError.corrupt }
    return text
  }
  func bool(_ key: String) throws -> Bool {
    guard let flag = value[key] as? Bool else { throw RepoError.corrupt }
    return flag
  }
  func optionalInt(_ key: String) -> Int64? { (value[key] as? NSNumber)?.int64Value }
  func optionalString(_ key: String) -> String? { value[key] as? String }
  // Одна страница ограничена по размеру, чтобы ответ целиком поместился в память телефона.
  func array(_ key: String, limit: Int = 128) throws -> [Any] {
    guard let list = value[key] as? [Any], list.count <= limit else { throw RepoError.corrupt }
    return list
  }
}
