import Foundation

@MainActor final class MediaAdmission: CaptureAdmission {
  private final class PendingCapture {
    let id = UUID(), kind: CaptureKind, token: MediaCancellation,
      completion: (Result<CaptureLease, Error>) -> Void
    var stopped = false, scheduled = false
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
  static func observePreviewAvailability(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    observers[id] = action
    return id
  }
  static func removePreviewObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  /// Обходит копию списка, чтобы обработчики могли менять свои подписки во время вызова.
  private static func notifyPreviewAvailability() {
    guard previewsAllowed else { return }
    for action in Array(observers.values) { action() }
  }
  /// Остановка видео может удалить его из списка. Обходим копию, чтобы остановить и остальные.
  private static func stopPreviews() { for stop in Array(previews.values) { stop() } }
  private static func clearDrain(_ id: UUID) { if drain?.0 == id { drain = nil } }
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
  func installPlaybackStopper(_ stop: @escaping (@escaping () -> Void) -> Void) {
    guard !closed else { return }
    stopper = stop
  }
  private func rejected<T>(_ error: MediaError, _ completion: @escaping (Result<T, Error>) -> Void)
    -> MediaCancellation
  {
    let token = MediaCancellation()
    token.onCancel { DispatchQueue.main.async { completion(.failure(MediaError.cancelled)) } }
    DispatchQueue.main.async { if token.finish() { completion(.failure(error)) } }
    return token
  }
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
  init(_ lease: PlaybackLease) { self.lease = lease }
  func begin() {
    precondition(!retired)
    work += 1
  }
  func end() {
    precondition(work > 0)
    work -= 1
    releaseIfRetired()
  }
  func retire() {
    retired = true
    releaseIfRetired()
  }
  private func releaseIfRetired() {
    if retired && work == 0 {
      lease?.release()
      lease = nil
    }
  }
  deinit { lease?.release() }
}
