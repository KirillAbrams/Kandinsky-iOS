// Читает и сохраняет маленькие изображения и форму звука. Проверки размера не дают заполнять
// таблицу тяжёлыми или повреждёнными данными.

import Foundation
enum MediaPreviewStorage {
  // Принимает строку с признаками малого изображения и проверяет размер до и после преобразования в байты.
  // Повреждённые или слишком крупные значения пропускает.
  static func tiny(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 4096, value.hasPrefix("/9j/"),
      let bytes = Data(base64Encoded: value), bytes.count <= 3072
    else { return nil }
    return value
  }
  // Принимает только непустой ряд не длиннее ста двадцати восьми точек. Пустая или чрезмерная
  // запись не сможет повлиять на вывод формы звука.
  static func waveform(_ value: [UInt8]?) -> [UInt8]? {
    guard let value, !value.isEmpty, value.count <= 128 else { return nil }
    return value
  }
  // Превращает проверенные точки звука в текст для таблицы. Если точек нет или преобразование не
  // удалось, хранилище может сохранить вложение без формы звука.
  static func waveJSON(_ value: [UInt8]?) -> String? {
    guard let value = waveform(value), let data = try? JSONEncoder().encode(value) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
  // Читает только короткую текстовую запись, разбирает точки и ещё раз проверяет их число.
  // Неверный формат не ломает загрузку вложения.
  static func readWave(_ value: SQLValue?) -> [UInt8]? {
    guard case let .text(text) = value, text.utf8.count <= 1024, let data = text.data(using: .utf8),
      let samples = try? JSONDecoder().decode([UInt8].self, from: data)
    else { return nil }
    return waveform(samples)
  }
  // Перезаписывает маленькое изображение и форму звука по номеру вложения. После обновления
  // старые значения не подмешиваются к новому содержимому.
  static func save(_ db: SQLiteConnection, id: String, tiny: String?, waveform: [UInt8]?) throws {
    try db.execute(
      "INSERT OR REPLACE INTO media_previews(attachmentID,tinyPreview,waveform) VALUES(?,?,?)",
      [
        .text(id), Self.tiny(tiny).map(SQLValue.text) ?? .null,
        waveJSON(waveform).map(SQLValue.text) ?? .null
      ])
  }
}
