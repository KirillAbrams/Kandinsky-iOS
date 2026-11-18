// Делит список чатов на закреплённые и календарные группы. По этим группам панель строит
// заголовки и порядок строк.

import Foundation

struct StudioHistorySection {
  let title: String
  let threads: [StudioThread]
}

enum StudioHistorySections {
  // Находит начало сегодня и вчера по календарю телефона, сортирует чаты по активности и номеру и
  // убирает пустые группы. Так день перевода часов и совпадение времени не ломают порядок.
  static func make(_ rows: [StudioThread], now: Date = Date(), calendar: Calendar = .current)
    -> [StudioHistorySection]
  {
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let ordered = rows.sorted {
      if $0.activityAtMs != $1.activityAtMs { return $0.activityAtMs > $1.activityAtMs }
      return $0.id > $1.id
    }
    let groups: [(String, (StudioThread) -> Bool)] = [
      ("Закреплённые", { $0.pinned }),
      ("Сегодня", { !$0.pinned && $0.activityAtMs >= Int64(today.timeIntervalSince1970 * 1000) }),
      (
        "Вчера",
        {
          !$0.pinned && $0.activityAtMs >= Int64(yesterday.timeIntervalSince1970 * 1000)
            && $0.activityAtMs < Int64(today.timeIntervalSince1970 * 1000)
        }
      ),
      ("Ранее", { !$0.pinned && $0.activityAtMs < Int64(yesterday.timeIntervalSince1970 * 1000) }),
    ]
    return groups.compactMap { title, matches in
      let threads = ordered.filter(matches)
      return threads.isEmpty ? nil : StudioHistorySection(title: title, threads: threads)
    }
  }
}
