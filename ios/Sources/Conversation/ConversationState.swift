// Хранит ввод, место чтения и ожидающие команды одного чата на айфоне. Перед отправкой записывает
// её номер, чтобы повтор после потери ответа не создал второе сообщение.

import CryptoKit
import Foundation

@MainActor final class ConversationState {
  private var pendingRetrySlots = Set<String>()

  // Проверяет, можно ли повторить результат, и отмечает ожидание для этого места. Получает тот же
  // номер из номера результата и предыдущего запуска даже после перезапуска телефона.
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

  // Снимает отметку ожидания по номеру результата. Следующая допустимая попытка не останется
  // заблокированной старым запросом.
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
    // При новой точке чтения заменяет ожидающую запись отдельной задачей. Поздняя запись текста
    // черновика не нужна для сохранения прокрутки.
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
  // Принимает хранилище чатов для чтения и записи. Экран передаёт уже готовое хранилище текущего
  // аккаунта.
  init(repository: ChatRepository) { self.repository = repository }
  // Читает ввод и точку чтения, затем помечает чат прочитанным. Просит показать готовое состояние
  // только если экран не закрылся во время ожидания.
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
  // Открывает заготовку без номера чата и переносит сохранённый ввод при наличии. Пользователь
  // может готовить запрос до создания истории на сервере.
  func openStudioDraft(_ restored: Draft? = nil) {
    guard !closed, chatID == nil else { return }
    if let restored { draft = restored }
    isReady = true
    onChange?()
  }
  // Присваивает готовой заготовке номер чата после его создания. Уже привязанный черновик нельзя
  // случайно перенести в другую историю.
  func bindStudioDraft(chatID: ChatID) {
    guard !closed, isReady, self.chatID == nil else { return }
    self.chatID = chatID
  }
  // Принимает свежий ввод, увеличивает его версию и сохраняет сведения об ожидающей отправке.
  // Несколько близких нажатий попадут в одну запись, а прежний запрос сохранит свой номер.
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
  // Запоминает изменившиеся настройки в черновике и планирует запись. При повторном открытии
  // параметры не сбросятся с ещё не отправленным запросом.
  func updateGenerationOptions(_ value: KandinskyOptions) {
    guard !closed, isReady, draft.generationOptions != value else { return }
    draft.generationOptions = value
    lastError = nil
    scheduleDraftSave()
    onChange?()
  }
  // Заменяет прежнюю ожидающую запись и ждёт паузу в наборе. Перед сохранением убирает отметку
  // ожидания, чтобы запись не отменила собственную задачу.
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
  // Сразу сохраняет черновик и заново берёт точку чтения после записи ввода. Прокрутка во время
  // медленной записи не будет затёрта прежним местом.
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
  // Сохраняет команду и номер, отправляет её и очищает только ту версию ввода, которую отправил.
  // При потере ответа остаётся команда для повтора, а более свежий текст не стирается.
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
  // Проверяет очередь файлов и сохраняет её до первой передачи. Убирает каждый принятый элемент
  // после сохранения остатка, поэтому повтор идёт с теми же номерами.
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
  // Запрещает новые действия, сохраняет оставшийся ввод и отсоединяет экранные уведомления.
  // Прежний чат больше не получает обновления через этот объект.
  func close() async {
    closed = true
    debounce?.cancel()
    try? await flush()
    isReady = false
    onDelta = nil
    onChange = nil
  }
  // Выбирает вид строки по вложению и его назначению. Без вложения остаётся текстовое сообщение.
  private static func kind(_ a: AttachmentDraft?) -> MessageKind {
    guard let a else { return .text }
    if a.thumbnailKey == "sticker" { return .sticker }
    if a.mime == "image/gif" { return .gif }
    if a.mime.hasPrefix("image/") { return .photo }
    if a.mime.hasPrefix("audio/") { return .voice }
    return a.thumbnailKey == "round" ? .round : .video
  }
}
