// Ведёт сетевой обмен выбранного аккаунта. Открывает связь на переднем плане, сохраняет ответы
// через местную базу и направляет изменения на экран.

import Foundation

@MainActor final class NetworkSync {
  let profile: NetworkProfile
  let local: SQLiteChatRepository
  let api: NetworkAPI
  let store: SQLiteStore
  let cache: NetworkStore
  let ui = NetworkUIBatch()

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var resumeTimeout: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var lastSocketPacketAt: TimeInterval = 0
  private(set) var connectionEpoch = 0
  private var reconnectAttempts = 0
  private(set) var active = false
  private(set) var closed = false
  private(set) var resumed = false
  private var rejectedSession = false
  private var nextActivityAt: TimeInterval = 0

  var outbox = OutboxState()
  var cursorAcknowledgement = CursorAcknowledgement()
  var history = HistorySyncState()
  var removalTask: Task<Void, Never>?
  var studioMedia: NetworkMedia?
  var onStudioMediaEvicted: (() -> Void)?
  var onDeltas: (([MessageDelta]) -> Void)?
  var onStatus: ((String) -> Void)?
  var onSessionExpired: (() -> Void)?
  var onAccountErased: (() -> Void)?
  var onStudioRecentChanged: (() -> Void)?
  var studioTransfers: [StudioTransfer] = []
  var onStudioTransfersChanged: (() -> Void)?

  // Связывает профиль, базу, местную историю и сетевой клиент. Передаёт отказ входа и готовые
  // изменения общим обработчикам, чтобы экран не следил за соединением сам.
  init(
    profile: NetworkProfile, store: SQLiteStore, local: SQLiteChatRepository, api: NetworkAPI? = nil
  ) {
    self.profile = profile
    self.store = store
    self.local = local
    cache = NetworkStore(userID: profile.userId)
    self.api = api ?? NetworkAPI(profile: profile)
    self.api.onSessionRejected = { [weak self] code in self?.sessionRejected(code) }
    ui.deliver = { [weak self] in self?.onDeltas?($0) }
  }

  // Отмечает действие владельца в серверном сеансе не чаще одного раза за тридцать секунд. При
  // обрыве следующее действие снова может подтвердить вход, а отказ доступа завершает сеанс.
  func userInteraction() {
    let now = ProcessInfo.processInfo.systemUptime
    guard !closed, !rejectedSession, now >= nextActivityAt else { return }
    nextActivityAt = now + 30
    Task {
      do {
        _ = try await api.json("/v1/kandinsky/activity", method: "POST")
      } catch let error as NetworkFailure where error.status == 401 {
        if !closed { sessionRejected(error.code) }
      } catch {
        // При временном обрыве следующее действие снова сможет подтвердить сеанс.
      }
    }
  }

  // Начинает связь при показе приложения и разрывает её при уходе с экрана. Это прекращает лишнюю
  // работу для скрытого приложения.
  func foreground(_ value: Bool) {
    guard !closed else { return }
    active = value
    if value { connect() } else { disconnect() }
  }
  /// У каждого подключения свой номер. По нему отбрасываем поздние ответы от уже закрытого соединения.
  // Выбирает первый снимок или список чатов, сохраняет его и просит события с последнего номера.
  // Проверяет номер подключения после ожиданий и ограничивает срок подтверждения, чтобы старые
  // ответы не влияли на восстановленную связь.
  private func connect() {
    guard active, !closed, socket == nil, receiveTask == nil else { return }
    connectionEpoch += 1
    let connectionID = connectionEpoch
    onStatus?("Подключение…")
    receiveTask = Task { [weak self] in
      guard let self else { return }
      do {
        let initialized = try await store.perform { [cache] in try cache.initialized($0) }
        if !initialized {
          let data = try await api.json("/v1/bootstrap")
          let deltas = try await store.perform { [cache] in try cache.bootstrap($0, data: data) }
          guard connectionID == connectionEpoch, active else { return }
          ui.offer(deltas)
        } else {
          let data = try await api.json("/v1/chats")
          let deltas = try await store.perform { [cache] in
            try cache.mergeChats($0, data: data, studioRecent: true)
          }
          guard connectionID == connectionEpoch, active else { return }
          ui.offer(deltas)
        }
        guard connectionID == connectionEpoch, active else { return }
        onStudioRecentChanged?()
        let cursor = try await store.perform { [cache] in try cache.cursor($0) }
        guard connectionID == connectionEpoch, active else { return }
        let connection = try api.socket()
        socket = connection
        resumeTimeout = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 15_000_000_000)
          guard !Task.isCancelled, let self, !self.resumed else { return }
          self.reconnectAfterFailure(connectionID)
        }
        try await send([
          "type": "resume", "cursor": cursor,
          "features": ["chatDirectory": true, "uploadProgress": true],
        ])
        while connectionID == connectionEpoch, active, !Task.isCancelled {
          let data = try await api.receive(connection)
          guard connectionID == connectionEpoch, !Task.isCancelled else { return }
          lastSocketPacketAt = ProcessInfo.processInfo.systemUptime
          try await receiveFrame(data, connectionID: connectionID)
        }
      } catch {
        guard connectionID == connectionEpoch, !Task.isCancelled else { return }
        if let failure = error as? NetworkFailure, failure.status == 401 {
          sessionRejected(failure.code)
        } else {
          reconnectAfterFailure(connectionID)
        }
      }
    }
  }

  // Снимает срок ожидания подтверждения, запускает проверку связи и продолжает очистку, отправку
  // и чтение открытого чата. Без этого сеть выглядела бы открытой, пока местная очередь ещё ждёт.
  func connectionResumed(connectionID: Int) {
    resumeTimeout?.cancel()
    resumeTimeout = nil
    resumed = true
    reconnectAttempts = 0
    onStatus?("В сети")
    startHeartbeat(connectionID)
    drainRemovedStudioMedia()

    kick()
    if let currentChat = history.currentChat { refreshVisibleHistory(currentChat) }
  }

  // Отправляет запрос удаления с паролем. Ответ о том, что аккаунт уже удалён, принимает как
  // завершение, поскольку подтверждение прежней попытки могло потеряться.
  func eraseStudioAccount(password: String) async throws {
    let body = try JSONEncoder().encode(["password": password])
    do {
      _ = try await api.json("/v1/kandinsky/account", body: body, method: "DELETE")
    } catch let failure as NetworkFailure
      where failure.status == 401 && failure.code == "account_deleted"
    {
      // Аккаунт мог удалиться на сервере до того, как телефон получил подтверждение.
    }
  }
  // Один раз останавливает связь и сообщает экрану, истёк вход или удалён аккаунт. Различие
  // важно, чтобы при удалении убрать местные сведения владельца.
  func sessionRejected(_ code: String) {
    guard !rejectedSession else { return }
    rejectedSession = true
    active = false
    disconnect()
    if code == "account_deleted" {
      onAccountErased?()
    } else {
      onSessionExpired?()
    }
  }

  // Проверяет наличие соединения и размер сообщения перед отправкой. Слишком большой или
  // непригодный пакет не передаётся, иначе он занял бы лишнее место в сетевой очереди.
  func send(_ value: [String: Any]) async throws {
    guard let socket else { throw RepoError.io }
    let data = try await api.encode(value)
    guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
      throw RepoError.invalidInput
    }
    try await socket.send(.string(text))
  }

  // После периода без входящих пакетов проверяет, отвечает ли ещё связь. Если ни ответ, ни другое
  // событие не пришли в отведённый срок, восстанавливает соединение.
  private func startHeartbeat(_ connectionID: Int) {
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(20))
        guard let self, !Task.isCancelled, self.connectionEpoch == connectionID, self.resumed else {
          return
        }
        let lastPacket = self.lastSocketPacketAt
        guard ProcessInfo.processInfo.systemUptime - lastPacket >= 20 else { continue }

        // Потерянная связь может выглядеть открытой, поэтому ограничиваем ожидание и отправки, и ответа
        let probe = Task { [weak self] in
          guard let self, !Task.isCancelled, self.connectionEpoch == connectionID else { return }
          do { try await self.send(["type": "ping"]) } catch {
            if !Task.isCancelled { self.reconnectAfterFailure(connectionID) }
          }
        }
        try? await Task.sleep(for: .seconds(10))
        probe.cancel()
        guard !Task.isCancelled, self.connectionEpoch == connectionID else { return }
        if self.lastSocketPacketAt == lastPacket {
          self.reconnectAfterFailure(connectionID)
          return
        }
      }
    }
  }
  // Разрывает только сбойное текущее соединение и увеличивает задержку при повторных отказах.
  // Очередь остаётся в базе, поэтому при восстановлении можно отправить неподтверждённые команды.
  func reconnectAfterFailure(_ connectionID: Int) {
    guard connectionID == connectionEpoch, active, !closed else { return }
    disconnect()
    onStatus?("Нет связи · сообщения сохранены")
    let next = connectionEpoch
    let delay =
      min(30, 0.5 * pow(2, Double(min(reconnectAttempts, 6)))) + Double.random(in: 0...0.25)
    reconnectAttempts += 1
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
      guard !Task.isCancelled, let self, self.connectionEpoch == next, self.active else { return }
      self.connect()
    }
  }
  // Меняет номер соединения, останавливает чтение, ожидания и сетевые проверки и сбрасывает
  // незавершённую отправку. Поздние ответы закрытого соединения теперь можно распознать.
  private func disconnect() {
    connectionEpoch += 1
    resumed = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    receiveTask?.cancel()
    receiveTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    resetOutbox()
    resetCursorAcknowledgement()
    resumeTimeout?.cancel()
    resumeTimeout = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }
  // Убирает обратные вызовы, останавливает работу с медиа и закрывает сетевой клиент и очередь
  // экрана. Иначе закрытый обмен мог бы продолжать держать ресурсы прежнего владельца.
  func close() {
    api.onSessionRejected = nil
    removalTask?.cancel()
    onStudioMediaEvicted = nil
    studioMedia = nil
    ui.close()
    onAccountErased = nil
    onSessionExpired = nil
    onStudioRecentChanged = nil
    onStudioTransfersChanged = nil
    studioTransfers = []
    closed = true
    active = false
    disconnect()
    onDeltas = nil
    onStatus = nil
    api.close()
  }
}
