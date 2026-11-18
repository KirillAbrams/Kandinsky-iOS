import Foundation

struct HistorySyncState {
  var currentChat: Int64?
  var loadingHistory: Set<Int64> = []
  var nextHistoryRetry: [Int64: TimeInterval] = [:]
  var visibleHistoryRefreshes: [Int64: TimeInterval] = [:]
}

extension NetworkSync {
  func viewport(chat: Int64, anchor: ReadingAnchor) {
    history.currentChat = chat
    guard let localID = anchor.messageID, !history.loadingHistory.contains(chat),
      Date.timeIntervalSinceReferenceDate > (history.nextHistoryRetry[chat] ?? 0)
    else { return }
    history.loadingHistory.insert(chat)
    let connectionID = connectionEpoch
    Task { [weak self] in
      guard let self else { return }
      defer { history.loadingHistory.remove(chat) }
      do {
        let before = try await store.perform { db -> Int64? in
          let count = try db.scalar(
            "SELECT count(*) FROM messages WHERE chatId=? AND sortKey<(SELECT sortKey FROM messages WHERE id=?)",
            [.integer(chat), .integer(localID)])
          guard count < 32,
            try db.scalar("SELECT hasOlder FROM net_chats WHERE chatID=?", [.integer(chat)]) != 0
          else { return nil }
          return try db.rows(
            """
            SELECT MIN(serverSeq) AS seq \
            FROM net_messages n \
            JOIN messages m ON m.id=n.localID \
            WHERE m.chatId=? AND serverSeq>0
            """,
            [.integer(chat)]
          ).first?["seq"]?.optionalInt
        }
        guard let before, active, connectionID == connectionEpoch else { return }
        let data = try await api.json("/v1/chats/\(chat)/history?limit=128&before=\(before)")
        let deltas = try await store.perform { [cache] in
          try cache.history($0, chat: chat, data: data)
        }
        if connectionID == connectionEpoch { ui.offer(deltas) }
      } catch { history.nextHistoryRetry[chat] = Date.timeIntervalSinceReferenceDate + 5 }
    }
  }
  func visibleChat(_ chat: Int64?) {
    let changed = history.currentChat != chat
    history.currentChat = chat
    if changed, let chat { refreshVisibleHistory(chat) }
  }
  func refreshVisibleHistory(_ chat: Int64) {
    let now = ProcessInfo.processInfo.systemUptime
    if resumed, let last = history.visibleHistoryRefreshes[chat], now - last < 90 { return }
    guard history.loadingHistory.insert(chat).inserted else { return }
    Task { [weak self] in
      guard let self else { return }
      defer { history.loadingHistory.remove(chat) }
      do {
        let data = try await api.json("/v1/chats/\(chat)/history?limit=128")
        guard !closed else { return }
        let deltas = try await store.perform { [cache] in
          try cache.history($0, chat: chat, data: data)
        }
        if !closed {
          history.visibleHistoryRefreshes[chat] = ProcessInfo.processInfo.systemUptime
          if history.visibleHistoryRefreshes.count > 32,
            let oldest = history.visibleHistoryRefreshes.min(by: { $0.value < $1.value })?.key
          {
            history.visibleHistoryRefreshes.removeValue(forKey: oldest)
          }
          ui.offer(deltas)
        }
      } catch {
        if history.currentChat == chat && !closed { onStatus?("История временно недоступна") }
      }
    }
  }
}
