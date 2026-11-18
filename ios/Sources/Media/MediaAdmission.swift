// Раздаёт места тихим роликам, большому проигрывателю и камере. Запрашивает остановку
// конкурирующей работы и ждёт подтверждения перед выдачей следующего места.

import Foundation

@MainActor final class MediaAdmission: CaptureAdmission {
  private final class PendingCapture {
    let id = UUID(), kind: CaptureKind, token: MediaCancellation,
      completion: (Result<CaptureLease, Error>) -> Void
    var stopped = false, scheduled = false
    // Запоминает вид съёмки, отмену и получателя права. Так ожидающую камеру можно снять, не
    // останавливая чужой запрос.
    init(
      _ kind: CaptureKind, _ token: MediaCancellation,
      _ completion: @escaping (Result<CaptureLease, Error>) -> Void
    ) {
      self.kind = kind
      self.token = token
      self.completion = completion
    }
  }
  private final class PendingPlayback {
    let id: UUID, token: MediaCancellation, completion: (Result<PlaybackLease, Error>) -> Void
    var scheduled = false
    // Собирает номер, отмену и ответ для ожидающего проигрывателя. По номеру узнаётся тот же
    // запрос после остановки тихих роликов.
    init(
      _ id: UUID, _ token: MediaCancellation,
      _ completion: @escaping (Result<PlaybackLease, Error>) -> Void
    ) {
      self.id = id
      self.token = token
      self.completion = completion
    }
  }
  private static var processPlayback: UUID?, processCapture: UUID?, processPendingCapture: UUID?
  private static var previews: [UUID: () -> Void] = [:]
  private static var drain: (UUID, () -> Void)?
  private static var observers: [UUID: () -> Void] = [:]
  static var previewOwnerCount: Int { previews.count }
  static var previewsAllowed: Bool {
    processPlayback == nil && processCapture == nil && processPendingCapture == nil
  }
  // Даёт тихому ролику место только при свободной камере и большом проигрывателе, соблюдая
  // предел. Возврат последнего места разрешает продолжить ожидающую общую операцию.
  static func reservePreview(studioAlbum: Bool = false, stop: @escaping () -> Void)
    -> PlaybackLease?
  {
    guard previewsAllowed, previews.count < (studioAlbum ? 4 : 2) else { return nil }
    let id = UUID()
    previews[id] = stop
    return PlaybackLease {
      releaseOnMain {
        guard previews.removeValue(forKey: id) != nil else { return }
        if previews.isEmpty { drain?.1() }
        notifyPreviewAvailability()
      }
    }
  }
  // Запоминает получателя уведомления под отдельным номером. Строка сможет попросить показ снова,
  // когда конкурирующая работа освободится.
  static func observePreviewAvailability(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    observers[id] = action
    return id
  }
  // Удаляет подписку по номеру. Ушедшая строка больше не должна просыпаться при возвращении
  // места.
  static func removePreviewObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  /// Обходит копию списка, чтобы обработчики могли менять свои подписки во время вызова.
  // Вызывает подписчиков только когда места снова можно выдавать и обходит копию списка. Один
  // получатель может отписаться, не мешая соседям.
  private static func notifyPreviewAvailability() {
    guard previewsAllowed else { return }
    for action in Array(observers.values) { action() }
  }
  /// Остановка видео может удалить его из списка. Обходим копию, чтобы остановить и остальные.
  // Просит все тихие просмотры остановиться и перебирает копию действий. Остановка может изменить
  // список прямо при вызове.
  private static func stopPreviews() { for stop in Array(previews.values) { stop() } }
  // Снимает ожидание, только если номер относится к уходящему запросу. Иначе старый отказ мог бы
  // убрать сигнал для другого ожидающего.
  private static func clearDrain(_ id: UUID) { if drain?.0 == id { drain = nil } }
  // Выполняет возврат места в потоке экрана или ставит его туда из фона. Список владельцев
  // меняется в одном потоке.
  nonisolated private static func releaseOnMain(_ action: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { action() }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }
  }
  private var closed = false, playbackID: UUID?, captureID: UUID?
  private var pendingCapture: PendingCapture?, pendingPlayback: PendingPlayback?
  private var stopper: ((@escaping () -> Void) -> Void)?
  var playbackActiveCount: Int { playbackID == nil ? 0 : 1 }
  var captureActiveCount: Int { captureID == nil ? 0 : 1 }
  /// После закрытия владельца новый обработчик не устанавливается.
  // Запоминает способ остановить текущий большой просмотр перед камерой. После закрытия такого
  // владельца новое действие не устанавливается.
  func installPlaybackStopper(_ stop: @escaping (@escaping () -> Void) -> Void) {
    guard !closed else { return }
    stopper = stop
  }
  // Возвращает отказ отложенно, пока есть возможность снять сам запрос. Завершение и отмена не
  // должны отдать два ответа.
  private func rejected<T>(_ error: MediaError, _ completion: @escaping (Result<T, Error>) -> Void)
    -> MediaCancellation
  {
    let token = MediaCancellation()
    token.onCancel { DispatchQueue.main.async { completion(.failure(MediaError.cancelled)) } }
    DispatchQueue.main.async { if token.finish() { completion(.failure(error)) } }
    return token
  }
  // Проверяет занятость камеры и общего места, записывает ожидание и останавливает тихие ролики.
  // Если запрос отменят, возвращает место и пробует продолжить съёмку.
  @discardableResult func requestPlayback(
    completion: @escaping (Result<PlaybackLease, Error>) -> Void
  ) -> MediaCancellation {
    guard !closed else { return rejected(.cancelled, completion) }
    guard captureID == nil, pendingCapture == nil, playbackID == nil, Self.processPlayback == nil,
      Self.processCapture == nil, Self.processPendingCapture == nil
    else { return rejected(.unavailable, completion) }
    let id = UUID(), token = MediaCancellation()
    playbackID = id
    Self.processPlayback = id
    pendingPlayback = PendingPlayback(id, token, completion)
    token.onCancel { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, let p = self.pendingPlayback, p.id == id else { return }
          self.pendingPlayback = nil
          Self.clearDrain(id)
          if Self.processPlayback == id { Self.processPlayback = nil }
          if self.playbackID == id { self.playbackID = nil }
          p.completion(.failure(MediaError.cancelled))
          self.tryGrant()
          Self.notifyPreviewAvailability()
        }
      }
    }
    Self.drain = (id, { [weak self] in self?.tryGrantPlayback() })
    Self.stopPreviews()
    tryGrantPlayback()
    return token
  }
  // Ждёт ухода всех тихих просмотров и отсутствие ожидающей камеры перед выдачей права. Возврат
  // выданного места снова разрешает ожидание и тихий показ.
  private func tryGrantPlayback() {
    guard !closed, pendingCapture == nil, Self.previews.isEmpty, let p = pendingPlayback,
      !p.scheduled
    else { return }
    p.scheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.pendingPlayback?.id == p.id, p.token.finish() else { return }
        self.pendingPlayback = nil
        Self.clearDrain(p.id)
        if self.closed {
          if Self.processPlayback == p.id { Self.processPlayback = nil }
          self.playbackID = nil
          p.completion(.failure(MediaError.cancelled))
          Self.notifyPreviewAvailability()
          return
        }
        p.completion(
          .success(
            PlaybackLease { [weak self] in
              Self.releaseOnMain {
                if Self.processPlayback == p.id { Self.processPlayback = nil }
                if let self, self.playbackID == p.id {
                  self.playbackID = nil
                  self.tryGrant()
                }
                Self.notifyPreviewAvailability()
              }
            }))
      }
    }
  }
  // Запоминает запрос на камеру, останавливает тихие ролики и просит закрыть свой большой
  // проигрыватель. Отмена снимает только ожидающее право, не меняя чужого владельца.
  @discardableResult func acquire(
    _ kind: CaptureKind, completion: @escaping (Result<CaptureLease, Error>) -> Void
  ) -> MediaCancellation {
    guard !closed else { return rejected(.cancelled, completion) }
    guard captureID == nil, pendingCapture == nil, Self.processCapture == nil,
      Self.processPendingCapture == nil,
      (Self.processPlayback == nil || Self.processPlayback == playbackID)
    else { return rejected(.unavailable, completion) }
    let token = MediaCancellation(), pending = PendingCapture(kind, token, completion)
    pendingCapture = pending
    Self.processPendingCapture = pending.id
    token.onCancel { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, let current = self.pendingCapture, current.id == pending.id else {
            return
          }
          self.pendingCapture = nil
          Self.clearDrain(pending.id)
          if Self.processPendingCapture == pending.id { Self.processPendingCapture = nil }
          if Self.processCapture == pending.id { Self.processCapture = nil }
          if self.captureID == pending.id { self.captureID = nil }
          current.completion(.failure(MediaError.cancelled))
          self.tryGrantPlayback()
          Self.notifyPreviewAvailability()
        }
      }
    }
    Self.drain = (pending.id, { [weak self] in self?.tryGrant() })
    Self.stopPreviews()
    let acknowledged = { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, let current = self.pendingCapture, current.id == pending.id else {
            return
          }
          current.stopped = true
          self.tryGrant()
        }
      }
    }
    if let stopper { stopper(acknowledged) } else { acknowledged() }
    return token
  }
  /// Выдаёт ожидающее разрешение записи только после подтверждения остановки и освобождения конкурирующих
  /// владельцев.
  // Выдаёт камеру после подтверждения остановки и ухода всех проигрывателей. Право возвращается
  // по номеру, чтобы позднее закрытие не снимало другую съёмку.
  private func tryGrant() {
    guard !closed, playbackID == nil, Self.processPlayback == nil, Self.processCapture == nil,
      Self.previews.isEmpty,
      let p = pendingCapture, Self.processPendingCapture == p.id, p.stopped, !p.scheduled
    else { return }
    p.scheduled = true
    captureID = p.id
    Self.processCapture = p.id
    Self.processPendingCapture = nil
    Self.clearDrain(p.id)
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.pendingCapture?.id == p.id, p.token.finish() else { return }
        self.pendingCapture = nil
        if self.closed {
          if Self.processCapture == p.id { Self.processCapture = nil }
          self.captureID = nil
          p.completion(.failure(MediaError.cancelled))
          Self.notifyPreviewAvailability()
          return
        }
        p.completion(
          .success(
            CaptureLease(kind: p.kind) { [weak self] in
              Self.releaseOnMain {
                if Self.processCapture == p.id { Self.processCapture = nil }
                if self?.captureID == p.id { self?.captureID = nil }
                Self.notifyPreviewAvailability()
              }
            }))
      }
    }
  }
  // Помечает владельца закрытым и снимает ожидающие запросы и текущий просмотр. Иначе экран мог
  // бы получить право после ухода.
  func close() {
    guard !closed else { return }
    closed = true
    pendingCapture?.token.cancel()
    pendingPlayback?.token.cancel()
    let stop = stopper
    stopper = nil
    stop?({})
  }
}

@MainActor final class PreviewLifetime {
  private var lease: PlaybackLease?, work = 0, retired = false
  // Сохраняет право тихого ролика до конца его открытия или остановки. Выдача нового места
  // зависит от того, успел ли старый владелец выйти.
  init(_ lease: PlaybackLease) { self.lease = lease }
  // Отмечает начало ещё одной работы внутри просмотра. Закрытое право больше не должно запускать
  // работу.
  func begin() {
    precondition(!retired)
    work += 1
  }
  // Уменьшает число незаконченных операций и пробует вернуть место. Без этого подготовка могла бы
  // удержать камеру после завершения.
  func end() {
    precondition(work > 0)
    work -= 1
    releaseIfRetired()
  }
  // Помечает просмотр завершённым, оставляя его место до окончания фоновой работы. Другой ролик
  // не начнёт работу поверх ещё живого ресурса.
  func retire() {
    retired = true
    releaseIfRetired()
  }
  // Возвращает право, только когда просмотр снят и работ больше нет. Затем убирает ссылку, чтобы
  // повтор не вернул место снова.
  private func releaseIfRetired() {
    if retired && work == 0 {
      lease?.release()
      lease = nil
    }
  }
  // Возвращает оставшееся право при освобождении объекта. Закрытый просмотр больше не занимает
  // место в общем списке.
  deinit { lease?.release() }
}
