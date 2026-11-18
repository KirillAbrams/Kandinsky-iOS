// Читает обязательные и необязательные поля ответа сервера. Ошибка обязательного поля
// останавливает запись, чтобы в историю не попали подставленные значения.

import CoreFoundation
import Foundation

// Разбор и сохранение выполняются в рабочей очереди базы, вне отрисовки экрана
struct WireObject {
  let value: [String: Any]
  // Требует, чтобы верхний уровень ответа был набором полей, и сохраняет его. Список или простое
  // значение не подходит для последующего чтения по имени.
  init(_ value: Any) throws {
    guard let object = value as? [String: Any] else { throw RepoError.corrupt }
    self.value = object
  }
  // Разбирает байты ответа и применяет ту же проверку верхнего уровня. Неверный формат
  // обнаружится до доступа к отдельным полям.
  init(data: Data) throws { try self.init(JSONSerialization.jsonObject(with: data)) }
  // Требует числовое поле и возвращает его как целое. Если обязательного номера нет, запись
  // нельзя сопоставить с чатом или событием.
  func int(_ key: String) throws -> Int64 {
    guard let number = value[key] as? NSNumber else { throw RepoError.corrupt }
    return number.int64Value
  }
  // Требует строковое поле и останавливает разбор при его отсутствии. Подстановка пустого текста
  // скрыла бы неполный ответ сервера.
  func string(_ key: String) throws -> String {
    guard let text = value[key] as? String else { throw RepoError.corrupt }
    return text
  }
  // Требует признак с двумя допустимыми значениями. Без него нельзя угадывать видимость или
  // состояние записи.
  func bool(_ key: String) throws -> Bool {
    guard let flag = value[key] as? Bool else { throw RepoError.corrupt }
    return flag
  }
  // Возвращает номер только если поле представлено числом. Отсутствие сохраняется отдельно от
  // нуля, чтобы вызывающий код мог выбрать нужный путь.
  func optionalInt(_ key: String) -> Int64? { (value[key] as? NSNumber)?.int64Value }
  // Читает строку, оставляя пустое значение при отсутствии поля или несовместимом виде. Это
  // позволяет принять ответ старого формата с необязательными сведениями.
  func optionalString(_ key: String) -> String? { value[key] as? String }
  // Требует список и проверяет число строк до дальнейшей обработки. Предел нужен, чтобы одна
  // порция не заняла слишком много памяти.
  func array(_ key: String, limit: Int = 128) throws -> [Any] {
    guard let list = value[key] as? [Any], list.count <= limit else { throw RepoError.corrupt }
    return list
  }
}
