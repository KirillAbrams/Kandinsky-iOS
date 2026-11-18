@testable import Kandinsky
import Foundation
enum SeedMediaPreviews {
  /// Записываем отметку готовности вместе с миниатюрами. Если установка прервётся, при запуске попробуем ещё
  /// раз.
  static func install(_ db: SQLiteConnection, fixtures: URL) throws {
    if !(try db.rows("SELECT 1 FROM metadata WHERE key='media-preview-catalog-v1'")).isEmpty {
      return
    }
    let data = try Data(contentsOf: fixtures.appendingPathComponent("media-previews-v1.json"))
    guard data.count <= 2 * 1024 * 1024,
      let entries = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
      entries.count <= 512
    else { throw RepoError.corrupt }
    try db.transaction {
      for entry in entries.values {
        let tiny = MediaPreviewStorage.tiny(entry["tinyPreview"] as? String),
          wave = (entry["waveform"] as? [Int]).flatMap { values -> [UInt8]? in
            guard values.count <= 128, values.allSatisfy({ (0...255).contains($0) }) else {
              return nil
            }
            return values.map(UInt8.init)
          }
        for key in [entry["relativePath"] as? String, entry["blobId"] as? String].compactMap({ $0 })
        {
          try db.execute(
            "INSERT OR REPLACE INTO media_preview_catalog(key,tinyPreview,waveform) VALUES(?,?,?)",
            [
              .text(key), tiny.map(SQLValue.text) ?? .null,
              MediaPreviewStorage.waveJSON(wave).map(SQLValue.text) ?? .null
            ])
        }
      }
      try db.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES('media-preview-catalog-v1','1')")
    }
  }
}
