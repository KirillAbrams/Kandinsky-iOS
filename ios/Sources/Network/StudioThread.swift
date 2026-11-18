// Описывает передаваемую карточку чата, страницу недавних и частичную правку свойств. Старые
// ответы могут не содержать времени активности и признака генерации.

import Foundation

struct StudioThread: Codable, Equatable, Sendable {
  let id: ChatID
  let title: String
  let lastSeq: Int64
  let unreadCount: Int64
  let pinned: Bool
  let archived: Bool
  let activityAtMs: Int64
  let generating: Bool

  // Собирает поля карточки с заданными значениями времени и генерации, если их не передали.
  // Виджет списка получает единый вид карточки и не читает сырой сетевой ответ.
  init(
    id: ChatID, title: String, lastSeq: Int64, unreadCount: Int64, pinned: Bool,
    archived: Bool, activityAtMs: Int64 = 0, generating: Bool = false
  ) {
    self.id = id
    self.title = title
    self.lastSeq = lastSeq
    self.unreadCount = unreadCount
    self.pinned = pinned
    self.archived = archived
    self.activityAtMs = activityAtMs
    self.generating = generating
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, lastSeq, unreadCount, pinned, archived, activityAtMs, generating
  }

  // Читает обязательные поля и подставляет значения только для двух необязательных. Так прежняя
  // форма ответа остаётся читаемой без потери важных признаков архива и закрепления.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try values.decode(ChatID.self, forKey: .id),
      title: try values.decode(String.self, forKey: .title),
      lastSeq: try values.decode(Int64.self, forKey: .lastSeq),
      unreadCount: try values.decode(Int64.self, forKey: .unreadCount),
      pinned: try values.decode(Bool.self, forKey: .pinned),
      archived: try values.decode(Bool.self, forKey: .archived),
      activityAtMs: try values.decodeIfPresent(Int64.self, forKey: .activityAtMs) ?? 0,
      generating: try values.decodeIfPresent(Bool.self, forKey: .generating) ?? false)
  }
}

struct StudioRecentPage: Sendable {
  static let catalogLimit = 200
  let threads: [StudioThread]
  let nextOffset: Int?
}

struct StudioThreadChange: Encodable {
  var title: String?
  var pinned: Bool?
  var archived: Bool?
}
