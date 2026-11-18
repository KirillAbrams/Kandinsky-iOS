import AVFoundation
import UIKit

struct PlaybackTarget: Equatable {
  let attachment: Attachment
  let messageID: MessageID
  var kind: MessageKind? = nil
  var loopPreview = false
}
@MainActor final class MediaCoordinator {
  let session = PlayerSession()
  private let admission: MediaAdmission, media: MediaStore
  private weak var output: AVPlayerLayer?
  private var lease: PlaybackLease?, request: MediaCancellation?
  private var generation = 0, closed = false
  private var wantsPlaying = false
  private var cacheGeneration = 0
  private var pendingRestore: Double?
  private var restoring = false
  private var downloadTask: Task<Void, Never>?

  private var observers: [NSObjectProtocol] = []
  private(set) var currentTarget: PlaybackTarget?
  var currentMessageID: MessageID? { currentTarget?.messageID }
  private var restoringSavedPosition: Bool { pendingRestore != nil || restoring }
  var isReady: Bool { session.ready && !restoringSavedPosition }
  var isPlaying: Bool { session.player.rate > 0 }
  var durationMs: Int64 { session.durationMs }
  var positionMs: Int64 { session.positionMs }
  private(set) var downloadProgress: Double?
  private(set) var lastError: Error?
  var onChange: (() -> Void)?
  var onDetachOutput: (() -> Void)?
  private var changeObservers: [UUID: () -> Void] = [:]
  func observeChanges(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    if !closed { changeObservers[id] = action }
    return id
  }
  func removeChangeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }
  var presentationOwner: UUID?

  init(admission: MediaAdmission, media: MediaStore) {
    self.admission = admission
    self.media = media
    admission.installPlaybackStopper { [weak self] done in
      guard let self else {
        done()
        return
      }
      self.stop(completed: done)
    }
    session.onChange = { [weak self] in
      self?.restoreIfReady()
      self?.notify()
    }
    session.onFailure = { [weak self] error in
      self?.lastError = error
      self?.stop()
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.stop() }
      })
  }
  func apply(_ delta: MessageDelta) {
    guard let target = currentTarget else { return }
    if delta.removedIDs.contains(target.messageID) {
      stop()
      return
    }
    guard let row = (delta.updated + delta.inserted).first(where: { $0.id == target.messageID })
    else { return }
    let stillPresent = row.attachments.contains { source in
      source.relativePath == target.attachment.relativePath && source.mime == target.attachment.mime
        && source.byteSize == target.attachment.byteSize
    }
    if !stillPresent || (target.kind != nil && row.kind != target.kind) { stop() }
  }
  /// При получении файла или потокового источника проверяет поколение запроса, чтобы поздний ответ не начал
  /// другое воспроизведение.
  func play(
    target: PlaybackTarget, startPaused: Bool = false, localOnly: Bool = false
  ) {
    guard !closed else { return }
    stop()
    guard target.attachment.mime.hasPrefix("video/") else {
      lastError = MediaError.unavailable
      notify()
      return
    }
    session.player.isMuted = true
    wantsPlaying = !startPaused
    currentTarget = target
    cacheGeneration = media.videoPlayback.generation
    downloadProgress = nil
    lastError = nil
    notify()
    let ticket = generation
    downloadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let source = try await media.playbackSource(target.attachment, localOnly: localOnly)
        do {
          if target.kind == .round {
            let duration = try await source.asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw MediaError.corrupt }
          }
          guard ticket == generation, !closed, !Task.isCancelled else {
            source.close()
            return
          }
          downloadTask = nil
          playPrepared(target: target, source: source)
        } catch {
          source.close()
          throw error
        }
      } catch {
        if ticket == generation {
          downloadTask = nil
          lastError = error
          notify()
        }
      }
    }
  }
  private func playPrepared(target: PlaybackTarget, source: MediaPlaybackSource) {
    guard !closed else { return }
    generation += 1
    let ticket = generation
    currentTarget = target
    lastError = nil
    downloadProgress = nil
    notify()
    // Возврат прежнего разрешения назначается раньше следующего запроса допуска
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.closed, self.generation == ticket else { return }
      self.request = self.admission.requestPlayback { [weak self] result in
        guard let self else {
          if case .success(let lease) = result { lease.release() }
          return
        }
        guard !self.closed, self.generation == ticket else {
          if case .success(let lease) = result { lease.release() }
          return
        }
        self.request = nil
        switch result {
        case .success(let lease):
          self.lease = lease
          let key = VideoPlaybackKey(messageID: target.messageID, attachment: target.attachment)
          let saved = self.media.videoPlayback.position(key)
          self.pendingRestore = saved > 0 ? saved : nil
          self.bindPlayerToOutput()
          self.session.replace(source: source, loop: target.kind == .round || target.loopPreview)
          if self.pendingRestore == nil, self.wantsPlaying { self.session.player.play() }
          self.restoreIfReady()
          self.notify()

        case .failure(let error):
          self.lastError = error
          self.currentTarget = nil
          self.notify()
        }
      }
    }
  }
  private func restoreIfReady() {
    guard session.ready, let saved = pendingRestore, !restoring else { return }
    pendingRestore = nil
    restoring = true
    let ticket = generation
    session.seek(ms: Int64(saved * 1000)) { [weak self] done in
      guard let self, self.generation == ticket, !self.closed else { return }
      self.restoring = false
      self.bindPlayerToOutput()
      if done, self.wantsPlaying { self.session.player.play() }
      self.notify()
    }
  }
  func rememberPlayback() {
    guard let target = currentTarget, session.ready, !restoring, pendingRestore == nil else {
      return
    }
    let key = VideoPlaybackKey(messageID: target.messageID, attachment: target.attachment)
    media.videoPlayback.rememberPosition(
      session.player.currentTime().seconds,
      key: key, generation: cacheGeneration)
    session.rememberFrame(in: media.videoPlayback, key: key, generation: cacheGeneration)
  }
  func attach(output layer: AVPlayerLayer) {
    if output !== layer { output?.player = nil }
    output = layer
    bindPlayerToOutput()
  }
  private func bindPlayerToOutput() {
    guard let output else { return }
    // Пока идёт перемотка, поверхность продолжает показывать сохранённый кадр.
    let player: AVPlayer? = restoringSavedPosition ? nil : session.player
    if output.player !== player { output.player = player }
  }
  func detach(output layer: AVPlayerLayer) {
    layer.player = nil
    if output === layer { output = nil }
  }
  func pause() {
    wantsPlaying = false
    session.player.pause()
    rememberPlayback()
    notify()
  }
  func resume(immediately: Bool = false) {
    wantsPlaying = true
    guard !closed, lease != nil, !restoringSavedPosition else { return }
    if durationMs > 0, positionMs >= durationMs - 50 {
      seek(ms: 0) { [weak self] done in
        guard let self, done, self.wantsPlaying else { return }
        self.resumeReadyPlayer(immediately: immediately)
      }
    } else {
      resumeReadyPlayer(immediately: immediately)
    }
  }
  private func resumeReadyPlayer(immediately: Bool) {
    if immediately {
      session.player.playImmediately(atRate: 1)
    } else {
      session.player.play()
    }
    notify()
  }
  func seek(ms: Int64, completion: @escaping (Bool) -> Void = { _ in }) {
    session.seek(ms: min(max(0, ms), max(0, durationMs)), completion: completion)
  }
  func stop(completed: @escaping () -> Void = {}) {
    rememberPlayback()
    generation += 1
    pendingRestore = nil
    restoring = false
    wantsPlaying = false
    downloadTask?.cancel()
    downloadTask = nil
    request?.cancel()
    request = nil
    currentTarget = nil
    downloadProgress = nil
    output?.player = nil
    output = nil
    onDetachOutput?()
    session.stop()
    lease?.release()
    lease = nil

    notify()
    completed()
  }
  private func notify() {
    onChange?()
    if !changeObservers.isEmpty { for action in Array(changeObservers.values) { action() } }
  }
  /// После закрытия новые запросы воспроизведения не принимаются.
  func close() {
    guard !closed else { return }
    closed = true
    changeObservers.removeAll()
    stop()
    session.onChange = nil
    session.onFailure = nil
    onChange = nil
    onDetachOutput = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }
}
