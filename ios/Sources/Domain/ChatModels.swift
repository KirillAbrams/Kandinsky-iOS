// Описывает сообщения, вложения, черновики и условия генерации. Хранилище, сетевой обмен и экран
// используют одни понятия, чтобы одинаково читать и показывать данные.

import Foundation

enum MessageKind: String, Codable, Sendable { case text, photo, video, voice, round, gif, sticker }
enum MessageDirection: String, Codable, Sendable { case incoming, outgoing }
enum MessageDelivery: String, Codable, Sendable {
  case local, pending, accepted, delivered, read, failed
}
enum MessageChangeReason: Sendable { case localSend, sync, history }
struct OrderKey: Codable, Equatable, Comparable, Sendable {
  let sortKey: Int64
  let messageID: MessageID
  // Сравнивает порядок по времени или серверной последовательности, а при равенстве по номеру
  // сообщения. Без второго сравнения границы страниц могли бы пропустить соседнюю строку.
  static func < (a: Self, b: Self) -> Bool {
    a.sortKey == b.sortKey ? a.messageID < b.messageID : a.sortKey < b.sortKey
  }
}
struct ChatSummary: Codable, Equatable, Sendable {
  let id: ChatID
  let title: String
  let lastPreview: String
  let lastSortKey: Int64
  let lastSavedAtMs: Int64
  let unreadCount: Int
  let pinned: Bool
  var archived = false, muted = false, markedUnread = false, hidden = false
}
struct Attachment: Codable, Equatable, Sendable {
  let id: String
  let relativePath: String
  let mime: String
  let byteSize: Int64
  let rawWidth: Int
  let rawHeight: Int
  let orientation: Int
  let durationMs: Int64?
  let thumbnailKey: String
  var tinyPreview: String? = nil
  var waveform: [UInt8]? = nil
  var remoteLocation: RemoteMediaLocation? = nil
}
struct AttachmentDraft: Codable, Equatable, Sendable {
  let id: String
  let relativePath: String
  let mime: String
  let byteSize: Int64
  var rawWidth: Int = 0
  var rawHeight: Int = 0
  var orientation: Int = 1
  var durationMs: Int64? = nil
  var thumbnailKey: String = ""
  var tinyPreview: String? = nil
  var waveform: [UInt8]? = nil
}
struct Message: Codable, Equatable, Sendable {
  let id: MessageID
  let chatID: ChatID
  let order: OrderKey
  let direction: MessageDirection
  let savedAtMs: Int64
  let kind: MessageKind
  let text: String
  let caption: String
  let replyToID: MessageID?
  let revision: Int
  let attachments: [Attachment]
  var delivery: MessageDelivery = .local
  var studioGeneration: StudioGeneration? = nil
  // Жалоба из истории доступна у входящего снимка или ролика с одним вложением.
  var canReportStudioMedia: Bool {
    direction == .incoming && attachments.count == 1 && (kind == .photo || kind == .video)
  }
}
// Причины жалобы имеют устойчивые значения для сервера и отдельные подписи для человека.
enum StudioReportReason: String, CaseIterable, Sendable {
  case inappropriate, harmful, other
  var title: String {
    switch self {
    case .inappropriate: return "Недопустимое содержание"
    case .harmful: return "Опасное или вредное содержание"
    case .other: return "Другая причина"
    }
  }
}
// Задаёт команды проверки, отмены и повтора, которые доступны рядом с заданием.
enum StudioGenerationAction: String, Sendable {
  case check, cancel, retry
  var title: String {
    switch self {
    case .check: return "Проверить"
    case .cancel: return "Отмена"
    case .retry: return "Повторить"
    }
  }
}
struct StudioGeneration: Codable, Equatable, Sendable {
  enum Stage: String, Codable, Sendable { case queued, running, failed, cancelled, succeeded }
  struct Slot: Codable, Equatable, Sendable {
    let id: String
    let status: Stage
    let blobId: String?
    let progress: Int?
    var runId: String? = nil
    var moderated: Bool? = nil

    // Разрешает повтор неудачного результата без файла, если проверка его не заблокировала.
    var canRetry: Bool { status == .failed && moderated != true && blobId == nil }
  }
  let stage: Stage
  let model: String?
  let aspect: String?
  let startedAtMs: Int64?
  let error: String?
  var moderated: Bool? = nil
  var slots: [Slot]? = nil
  var progress: Int? = nil
  private enum CodingKeys: String, CodingKey {
    case stage = "kandinskyStatus"
    case model = "kandinskyModel"
    case aspect = "kandinskyAspect"
    case startedAtMs = "kandinskyStartedAtMs"
    case error = "kandinskyError"
    case moderated = "kandinskyModerated"
    case slots = "kandinskySlots"
    case progress = "kandinskyProgress"
  }
  static let statusTexts: Set<String> = [
    "Генерация продолжается", "В очереди", "Генерация", "Время вышло", "Не удалось создать",
    "Генерация отменена", "Генерация заблокирована после проверки",
  ]
  // Считает активными ожидание в очереди и выполнение, чтобы остановку не предлагать после конца.
  var isActive: Bool { stage == .queued || stage == .running }
  // Относит обычный ролик и улучшение ролика к видео для выбора оформления.
  var isVideo: Bool { model == "video" || model == "video_sr" }
  // Считает ширину к высоте из двух положительных чисел. Неверные пропорции заменяет квадратом.
  var ratio: Double {
    let values = aspect?.split(separator: ":").compactMap { Double($0) } ?? []
    guard values.count == 2, values[0] > 0, values[1] > 0 else { return 1 }
    let ratio = values[0] / values[1]
    return ratio.isFinite && (0.1...10).contains(ratio) ? ratio : 1
  }
  // Показывает отдельную подпись отмены или объяснение сбоя. Без ответа службы даёт подсказку о повторе.
  var failureText: String {
    stage == .cancelled
      ? "Генерация отменена"
      : (error?.isEmpty == false ? error! : "Не удалось создать. Попробуйте ещё раз.")
  }
}
struct KandinskyOptions: Codable, Equatable, Sendable {
  var model = "image"
  var aspect = "1:1"
  var duration_seconds = 5

  var quality: String?
  var resolution: String?
  var count: Int?
  var seed: Int?
  var negative_prompt: String?
  var guidance_scale: Double?

  // Собирает параметры запроса и оставляет только заданные дополнительные поля.
  var wire: [String: Any] {
    var value: [String: Any] = [
      "model": model, "aspect": aspect, "duration_seconds": duration_seconds,
    ]
    value["quality"] = quality
    value["resolution"] = resolution
    value["count"] = count
    value["seed"] = seed
    value["negative_prompt"] = negative_prompt
    value["guidance_scale"] = guidance_scale
    return value
  }
}

struct StudioUpload: Decodable, Sendable {
  let blobId: String
  let mime: String
  let byteSize: Int64
  // Определяет ролик по виду файла, чтобы открыть видео вместо использования снимка.
  var isVideo: Bool { mime == "video/mp4" }
  // Подписывает команду по виду файла. Ролик можно смотреть, а снимок использовать как исходник.
  var title: String { isVideo ? "Посмотреть загруженное видео" : "Использовать загруженное фото" }
}
struct StudioDraftRecord: Codable, Sendable {
  let identity: UUID
  let draft: Draft
  // Проверяет ввод, файлы, ожидающие отправки и настройки, чтобы сохранить незаконченный черновик.
  var hasContent: Bool {
    !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !draft.attachmentDrafts.isEmpty || draft.pendingSend != nil
      || draft.pendingMediaBatch != nil || draft.generationOptions != nil
  }
}

struct StudioTransfer: Decodable, Sendable, Equatable {
  let id: String
  let deviceId: String
  let received: Int64
  let total: Int64
  let mime: String
  // Проверяет номера, допустимый размер и счётчик переданных байтов до показа загрузки.
  var isValid: Bool {
    UUID(uuidString: id) != nil && (deviceId.isEmpty || UUID(uuidString: deviceId) != nil)
      && (1...20 * 1024 * 1024).contains(total) && (0...total).contains(received)
      && mime.utf8.count <= 80
  }
  // Делит переданное на полный объём после проверки счётчиков. Доля сохраняется до округления на экране.
  var progress: Double { Double(received) / Double(total) }
}
struct StudioChoice: Decodable, Sendable {
  let id: String
  let name: String
  let sizes: [String: [Int]]?

  // Возвращает размеры выбранного формата для выбранного соотношения сторон либо его обычное
  // название. Интерфейс не подставит размеры другого кадра, если нужных данных нет.
  func label(aspect: String) -> String {
    sizes?[aspect]?.map(String.init).joined(separator: " × ") ?? name
  }
}

struct StudioGuidance: Decodable, Sendable {
  let min: Double
  let max: Double
  let `default`: Double
}

struct StudioCapabilities: Decodable, Sendable {
  let quality: [StudioChoice]
  let resolutions: [StudioChoice]
  let aspects: [String]
  let duration_seconds: [Int]
  let max_count: Int
  let negative_prompt: Bool
  let guidance: StudioGuidance?
}

struct StudioModel: Decodable, Sendable {
  let id: String
  let name: String
  let description: String
  let capabilities: StudioCapabilities?
  let reference_capabilities: StudioCapabilities?

  private enum CodingKeys: String, CodingKey {
    case id, name, description, capabilities, reference_capabilities
  }

  // Читает название и описание модели, а также её доступные параметры и настройки для исходника.
  // Улучшение видео не требует такого набора, поэтому отсутствие этих полей не ломает весь
  // список.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    description = try values.decode(String.self, forKey: .description)
    if id == "video_sr" {
      capabilities = nil
      reference_capabilities = nil
    } else {
      capabilities = try values.decode(StudioCapabilities.self, forKey: .capabilities)
      reference_capabilities = try values.decodeIfPresent(
        StudioCapabilities.self, forKey: .reference_capabilities)
    }
  }
}

// Сохраняет одну операцию отправки с номером, который нужен при повторе после потери ответа.
struct SendCommand: Codable, Equatable, Sendable {
  let operationID: String
  let chatID: ChatID
  var kind: MessageKind = .text
  var text: String = ""
  var caption: String = ""
  var replyToID: MessageID? = nil
  var attachments: [AttachmentDraft] = []
  var generationOptions: KandinskyOptions? = nil
}
// Передаёт только добавленные, изменённые и удалённые строки, чтобы не перечитывать весь чат.
struct MessageDelta: Sendable {
  var inserted: [Message] = []
  var updated: [Message] = []
  var removedIDs: [MessageID] = []
  let chat: ChatSummary
  var reason: MessageChangeReason = .localSend
}
// Хранит ввод и ожидающие действия отдельно от уже отправленных сообщений.
struct Draft: Codable, Equatable, Sendable {
  var text: String = ""
  var attachmentDrafts: [AttachmentDraft] = []
  var replyToID: MessageID? = nil
  var revision: Int64 = 0
  var operationID: String? = nil
  var pendingSend: SendCommand? = nil
  var pendingRevision: Int64? = nil
  var pendingMediaBatch: [SendCommand]? = nil
  var generationOptions: KandinskyOptions? = nil
}
// Запоминает место чтения внутри строки и версию раскладки для возврата после закрытия чата.
struct ReadingAnchor: Codable, Equatable, Sendable {
  var messageID: MessageID? = nil
  var fraction: Double = 0
  var textUTF16Offset: Int? = nil
  var screenDelta: Double = 0
  var followsBottom: Bool = true
  var layoutVersion: Int = 1
}
struct IndexedRow: Sendable {
  let messageID: MessageID
  let order: OrderKey
  let estimatedHeight: Double
  let revision: Int
  let savedAtMs: Int64?
  // Собирает краткую строку для расчёта истории из номера, порядка, примерной высоты и версии.
  // Календарная отметка может отсутствовать, чтобы старые сведения тоже можно было открыть.
  init(
    messageID: MessageID, order: OrderKey, estimatedHeight: Double, revision: Int,
    savedAtMs: Int64? = nil
  ) {
    self.messageID = messageID
    self.order = order
    self.estimatedHeight = estimatedHeight
    self.revision = revision
    self.savedAtMs = savedAtMs
  }
}
