// Здесь описаны адресные сведения о файле из истории и проверка перед скачиванием.
// Номер обложки хранится отдельно от оригинала, поэтому можно запросить нужный вариант.

import Foundation

struct RemoteMediaLocation: Codable, Equatable, Sendable {
  let blobID: String
  let previewBlobID: String?
  let mime: String
  let byteSize: Int64

  // Принимает только номера из шестнадцатеричных цифр ожидаемой длины.
  // Остальные строки не попадут в адрес скачивания или имя местного файла.
  static func validBlobID(_ value: String) -> Bool {
    [32, 64].contains(value.utf8.count)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  // Сверяет номер оригинала, необязательный номер обложки и размер файла.
  // Лента может отсеять неправильную запись ещё до начала скачивания.
  var isValid: Bool {
    Self.validBlobID(blobID)
      && (previewBlobID.map(Self.validBlobID) ?? true)
      && (1...67_108_864).contains(byteSize)
  }
}
