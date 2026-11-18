import CryptoKit
import Foundation

@MainActor final class ConversationState {
  private var pendingRetrySlots = Set<String>()

  // Один и тот же неудачный запуск получает один номер повтора, в том числе после перезапуска телефона.
  func beginSlotRetry(_ slot: StudioGeneration.Slot) -> UUID? {
    guard slot.canRetry else { return nil }
    let id = slot.id
    let run = slot.runId
    guard pendingRetrySlots.insert(id).inserted else { return nil }
    let key = "kandinsky/retry/" + id.lowercased() + "/" + (run?.lowercased() ?? "initial")
    var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
        bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  func finishSlotRetry(_ id: String) {
    pendingRetrySlots.remove(id)
  }

  private let repository: ChatRepository
  private var debounce: Task<Void, Never>?
  private var positionWrite: Task<Void, Never>?
  private var closed = false
  private(set) var chatID: ChatID?
  private(set) var draft = Draft()
  var anchor: ReadingAnchor? {
    didSet {
      guard anchor != oldValue, !closed, isReady, let id = chatID, let position = anchor else { return }
      // Место чтения сохраняем отдельно от черновика, чтобы остановка процесса не вернула чат в конец.
      positionWrite?.cancel()
      positionWrite = Task { [weak self] in
        guard let self, !self.closed, !Task.isCancelled else { return }
        do {
          try await self.repository.savePosition(chatID: id, anchor: position)
        } catch {
          guard !Task.isCancelled, !self.closed else { return }
          self.lastError = error
          self.onChange?()
        }
      }
    }
  }
  private(set) var lastError: Error?
  private(set) var isSending = false
  private(set) var isReady = false
  var onDelta: ((MessageDelta) -> Void)?
  var onChange: (() -> Void)?
  var persistStudioDraft: ((ChatID?, Draft) async throws -> Void)?
  init(repository: ChatRepository) { self.repository = repository }
  // Поздний ответ хранилища может прийти уже после ухода с экрана.
  func open(chatID: ChatID) async throws {
    closed = false
    isReady = false
    self.chatID = chatID
    draft = try await repository.draft(chatID: chatID)
    anchor = try await repository.position(chatID: chatID)
    try await repository.markRead(chatID: chatID)
    guard !closed else { throw RepoError.cancelled }
    isReady = true
    onChange?()
  }
  func openStudioDraft(_ restored: Draft? = nil) {
    guard !closed, chatID == nil else { return }
    if let restored { draft = restored }
    isReady = true
    onChange?()
  }
  // Первая отправка получает номер чата после подтверждения сервера.
  func bindStudioDraft(chatID: ChatID) {
    guard !closed, isReady, self.chatID == nil else { return }
    self.chatID = chatID
  }
  // Печать сразу видна на экране. Запись откладываем, чтобы сохранять несколько нажатий вместе.
  func editDraft(_ value: Draft) {
    guard !closed, isReady else { return }
    var value = value
    value.revision = draft.revision + 1
    value.operationID = draft.operationID
    value.pendingSend = draft.pendingSend
    value.pendingRevision = draft.pendingRevision
    value.pendingMediaBatch = draft.pendingMediaBatch
    draft = value
    lastError = nil
    scheduleDraftSave()
    onChange?()
  }
  func updateGenerationOptions(_ value: KandinskyOptions) {
    guard !closed, isReady, draft.generationOptions != value else { return }
    draft.generationOptions = value
    lastError = nil
    scheduleDraftSave()
    onChange?()
  }
  private func scheduleDraftSave() {
    debounce?.cancel()
    debounce = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled, let self else { return }
      // Задержка закончилась. Запись не должна отменять собственную задачу.
      self.debounce = nil
      do { try await self.flush() } catch {
        self.lastError = error
        self.onChange?()
      }
    }
  }
  // Перед уходом записываем черновик и место чтения, даже если таймер сохранения ещё не сработал.
  func flush() async throws {
    debounce?.cancel()
    debounce = nil
    positionWrite?.cancel()
    positionWrite = nil
    guard isReady else { return }
    let value = draft
    guard let id = chatID else {
      try await persistStudioDraft?(nil, value)
      return
    }
    try await repository.saveDraft(chatID: id, draft: value)
    try await persistStudioDraft?(id, value)
    // Пока записывался черновик, пользователь мог прокрутить дальше.
    if let position = anchor { try await repository.savePosition(chatID: id, anchor: position) }
  }
  // Сохраняем номер отправки до обращения к сети. При потере ответа ту же команду можно отправить снова.
  func send(generationOptions: KandinskyOptions? = nil) async {
    if draft.pendingMediaBatch != nil {
      await sendMediaBatch()
      return
    }
    guard isReady, !isSending, !closed, let id = chatID else { return }
    guard
      draft.pendingSend != nil
        || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.attachmentDrafts.isEmpty
    else { return }
    isSending = true
    lastError = nil
    debounce?.cancel()
    debounce = nil
    if draft.pendingSend == nil {
      let token = UUID().uuidString
      let kind = Self.kind(draft.attachmentDrafts.first)
      draft.operationID = token
      draft.pendingRevision = draft.revision
      draft.pendingSend = SendCommand(
        operationID: token, chatID: id, kind: kind, text: kind == .text ? draft.text : "",
        caption: kind == .text ? "" : draft.text, replyToID: draft.replyToID,
        attachments: draft.attachmentDrafts, generationOptions: generationOptions)
    }
    let command = draft.pendingSend!
    let revision = draft.pendingRevision ?? draft.revision
    onChange?()
    do {
      try await flush()
      let delta = try await repository.send(command)
      if draft.revision == revision {
        draft = Draft(
          revision: draft.revision + 1, generationOptions: draft.generationOptions)
      } else {
        draft.operationID = nil
        draft.pendingSend = nil
        draft.pendingRevision = nil
        draft.revision += 1
      }
      try await flush()
      onDelta?(delta)
    } catch { lastError = error }
    isSending = false
    onChange?()
  }
  // Каждый файл получает постоянный номер до отправки. После сбоя продолжаем ту же группу.
  func sendMediaBatch(_ commands: [SendCommand]? = nil) async {
    guard isReady, !isSending, !closed, let id = chatID, draft.pendingSend == nil else { return }
    if let commands {
      guard !commands.isEmpty, commands.count <= 32,
        commands.allSatisfy({
          $0.chatID == id && UUID(uuidString: $0.operationID) != nil && $0.attachments.count <= 10
        }),
        Set(commands.map(\.operationID)).count == commands.count,
        commands.reduce(0, { $0 + $1.attachments.count }) <= 32,
        draft.pendingMediaBatch.map({ commands.suffix($0.count).elementsEqual($0) }) ?? true
      else {
        lastError = RepoError.invalidInput
        onChange?()
        return
      }
      if draft.pendingMediaBatch == nil {
        draft.pendingMediaBatch = commands
        draft.revision += 1
      }
    }
    guard draft.pendingMediaBatch?.isEmpty == false else { return }
    isSending = true
    lastError = nil
    debounce?.cancel()
    debounce = nil
    onChange?()
    defer {
      isSending = false
      onChange?()
    }
    do {
      try await flush()
      while let queue = draft.pendingMediaBatch, let command = queue.first {
        guard !closed else { throw RepoError.cancelled }
        let delta = try await repository.send(command)
        guard !closed else { throw RepoError.cancelled }
        onDelta?(delta)
        draft.pendingMediaBatch = queue.count == 1 ? nil : Array(queue.dropFirst())
        draft.revision += 1
        do { try await flush() } catch {
          draft.pendingMediaBatch = queue
          draft.revision += 1
          throw error
        }
      }
    } catch { lastError = error }
  }
  func close() async {
    closed = true
    debounce?.cancel()
    try? await flush()
    isReady = false
    onDelta = nil
    onChange = nil
  }
  private static func kind(_ a: AttachmentDraft?) -> MessageKind {
    guard let a else { return .text }
    if a.thumbnailKey == "sticker" { return .sticker }
    if a.mime == "image/gif" { return .gif }
    if a.mime.hasPrefix("image/") { return .photo }
    if a.mime.hasPrefix("audio/") { return .voice }
    return a.thumbnailKey == "round" ? .round : .video
  }
}
