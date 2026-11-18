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
  var canReportStudioMedia: Bool {
    direction == .incoming && attachments.count == 1 && (kind == .photo || kind == .video)
  }
}
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
  var isActive: Bool { stage == .queued || stage == .running }
  var isVideo: Bool { model == "video" || model == "video_sr" }
  var ratio: Double {
    let values = aspect?.split(separator: ":").compactMap { Double($0) } ?? []
    guard values.count == 2, values[0] > 0, values[1] > 0 else { return 1 }
    let ratio = values[0] / values[1]
    return ratio.isFinite && (0.1...10).contains(ratio) ? ratio : 1
  }
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
  var isVideo: Bool { mime == "video/mp4" }
  var title: String { isVideo ? "Посмотреть загруженное видео" : "Использовать загруженное фото" }
}
struct StudioDraftRecord: Codable, Sendable {
  let identity: UUID
  let draft: Draft
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
  var isValid: Bool {
    UUID(uuidString: id) != nil && (deviceId.isEmpty || UUID(uuidString: deviceId) != nil)
      && (1...20 * 1024 * 1024).contains(total) && (0...total).contains(received)
      && mime.utf8.count <= 80
  }
  var progress: Double { Double(received) / Double(total) }
}
struct StudioChoice: Decodable, Sendable {
  let id: String
  let name: String
  let sizes: [String: [Int]]?

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
struct MessageDelta: Sendable {
  var inserted: [Message] = []
  var updated: [Message] = []
  var removedIDs: [MessageID] = []
  let chat: ChatSummary
  var reason: MessageChangeReason = .localSend
}
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
