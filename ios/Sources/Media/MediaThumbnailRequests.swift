// Объединяет просьбы показать один кадр в одну подготовку и загрузку. Видимый запрос может
// отложить раннее чтение другого файла.

import Foundation

/// Одна передача и одно декодирование обслуживают всех владельцев одного кадра.
@MainActor final class MediaThumbnailRequests {
  typealias Start = (
    Int, @escaping () -> Bool, @escaping (Double) -> Void,
    @escaping (Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation
  private final class Subscriber {
    let token = MediaCancellation()
    let priority: Int
    let progress: (Double) -> Void
    let localMiss: () -> Void
    let completion: (Result<PreparedImage, Error>) -> Void
    // Запоминает срочность и действия для отдельного получателя. У каждого экрана остаются свои
    // ответы, даже если работа общая.
    init(
      _ priority: Int, _ progress: @escaping (Double) -> Void, _ localMiss: @escaping () -> Void,
      _ completion: @escaping (Result<PreparedImage, Error>) -> Void
    ) {
      self.priority = priority
      self.progress = progress
      self.localMiss = localMiss
      self.completion = completion
    }
  }
  private final class Group {
    let key: String
    let start: Start
    let owners = MediaRequestOwners()
    var subscribers: [UUID: Subscriber] = [:]
    var work: MediaCancellation?
    var generation = 0
    var running = false
    var remote = false
    var priority: Int { subscribers.values.map(\.priority).max() ?? 0 }
    // Запоминает ключ кадра и способ начать подготовку. Следующий запрос с таким ключом может
    // присоединиться к прежнему.
    init(_ key: String, _ start: @escaping Start) {
      self.key = key
      self.start = start
    }
  }
  private var groups: [String: Group] = [:]
  private var order: [String] = []
  var onRemoteActivity: ((Bool) -> Void)?

  // Находит открытую группу или создаёт её до предела, затем привязывает отмену отдельного
  // получателя. Если последняя подписка исчезла, новый запрос не попадёт в уже закрытую передачу.
  func submit(
    key: String, priority: Int, progress: @escaping (Double) -> Void,
    localMiss: @escaping () -> Void = {},
    start: @escaping Start, completion: @escaping (Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation {
    let subscriber = Subscriber(priority, progress, localMiss, completion)
    let id = UUID()
    guard groups[key] != nil || groups.count < 32 else {
      DispatchQueue.main.async {
        _ = subscriber.token.finish()
        completion(.failure(MediaError.unavailable))
      }
      return subscriber.token
    }
    var group = groups[key] ?? Group(key, start)
    while !group.owners.insert(id) {
      retire(group)
      group = groups[key] ?? Group(key, start)
    }
    if groups[key] == nil {
      groups[key] = group
      order.append(key)
    }
    group.subscribers[id] = subscriber
    subscriber.token.onCancel { [weak self, weak group] in
      group?.owners.remove(id)
      let cancel: @MainActor () -> Void = {
        guard let self, let group, group.subscribers.removeValue(forKey: id) != nil else { return }
        completion(.failure(MediaError.cancelled))
        if group.subscribers.isEmpty { self.remove(group) }
        self.resumeWaiting()
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated { cancel() }
      } else {
        DispatchQueue.main.async { cancel() }
      }
    }
    if !group.running {
      launch(group)
    } else if group.remote {
      let generation = group.generation
      DispatchQueue.main.async { [weak group, weak subscriber] in
        guard let group, let subscriber, group.remote, group.generation == generation,
          !subscriber.token.isCancelled
        else { return }
        subscriber.localMiss()
      }
    }
    return subscriber.token
  }

  // Начинает подготовку и при переходе к сети даёт видимым запросам преимущество. Перед выдачей
  // удерживает кадр отдельно для всех получателей, чтобы первый из них мог закрыть экран без
  // потери остальных ответов.
  private func launch(_ group: Group) {
    guard !group.owners.isClosed else { return }
    group.running = true
    group.remote = false
    group.generation += 1
    let generation = group.generation
    group.work = group.start(
      group.priority,
      { [weak self, weak group] in
        guard let self, let group, self.groups[group.key] === group,
          group.generation == generation
        else { return false }
        if group.priority > 0 {
          for other in Array(self.groups.values)
          where other !== group && other.remote && other.priority <= 0 { self.pause(other) }
        } else if self.groups.values.contains(where: { $0 !== group && $0.remote }) {
          self.pause(group)
          return false
        }
        group.remote = true
        for subscriber in Array(group.subscribers.values) where !subscriber.token.isCancelled {
          subscriber.localMiss()
        }
        self.onRemoteActivity?(true)
        return true
      },
      { [weak group] value in
        guard let group, group.generation == generation else { return }
        for subscriber in Array(group.subscribers.values) where !subscriber.token.isCancelled {
          subscriber.progress(value)
        }
      },
      { [weak self, weak group] result in
        guard let self, let group, self.groups[group.key] === group,
          group.generation == generation
        else {
          if case .success(let frame) = result { frame.close() }
          return
        }
        // Удержания создаются до вызова получателей: один из них может очистить кэш или закрыть экран.
        let deliveries = group.subscribers.values.map { subscriber in
          (
            subscriber,
            result.flatMap { frame in
              frame.retained().map { .success($0) } ?? .failure(MediaError.cancelled)
            }
          )
        }
        if case .success(let frame) = result { frame.close() }
        self.remove(group)
        for (subscriber, delivery) in deliveries {
          if subscriber.token.finish() {
            subscriber.completion(delivery)
          } else {
            if case .success(let frame) = delivery { frame.close() }
            subscriber.completion(.failure(MediaError.cancelled))
          }
        }
        self.resumeWaiting()
      })
    if let work = group.work { group.owners.cancellation.onCancel { work.cancel() } }
  }

  // Меняет номер попытки и отменяет работу, оставляя подписки. Это позволяет продолжить фоновый
  // запрос позже и отбросить прежний ответ.
  private func pause(_ group: Group) {
    group.generation += 1
    group.running = false
    group.remote = false
    group.work?.cancel()
    group.work = nil
  }
  // Убирает группу из карты и порядка ожидания, отменяет задачу и освобождает подписки. Новая
  // работа по этому ключу начнётся отдельно.
  private func remove(_ group: Group) {
    groups.removeValue(forKey: group.key)
    order.removeAll { $0 == group.key }
    pause(group)
    group.owners.close()
    group.subscribers.removeAll()
  }
  // Снимает группу и сообщает отмену каждому оставшемуся получателю. Так ни один экран не ждёт
  // ответа от уже закрытой работы.
  private func retire(_ group: Group) {
    let subscribers = Array(group.subscribers.values)
    remove(group)
    for subscriber in subscribers {
      _ = subscriber.token.finish()
      subscriber.completion(.failure(MediaError.cancelled))
    }
  }
  // Запускает срочные группы и при свободной сети одну раннюю. Сообщает, осталась ли передача,
  // чтобы подготовка видео могла уступить ей.
  private func resumeWaiting() {
    let waiting = order.compactMap { groups[$0] }.filter { !$0.running }
    for group in waiting where group.priority > 0 { launch(group) }
    if !groups.values.contains(where: { $0.remote }),
      let group = waiting.first(where: { $0.priority <= 0 && !$0.running })
    {
      launch(group)
    }
    onRemoteActivity?(groups.values.contains(where: { $0.remote }))
  }
  // Снимает все группы и сообщает, что сеть больше не занята картинками. Выход из чата прерывает
  // даже общие запросы.
  func clear() {
    let active = Array(groups.values)
    for group in active { retire(group) }
    onRemoteActivity?(false)
  }
}
