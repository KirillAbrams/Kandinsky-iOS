// Связывает экран просмотра, право проигрывания и сохранённое время. При смене вложения
// останавливает прежний источник до открытия следующего.

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
  // Добавляет получателя изменений под отдельным номером, если владелец ещё открыт. Экран может
  // снять свою подписку независимо.
  func observeChanges(_ action: @escaping () -> Void) -> UUID {
    let id = UUID()
    if !closed { changeObservers[id] = action }
    return id
  }
  // Убирает получателя по его номеру. Ушедшая страница не должна получать изменения чужого видео.
  func removeChangeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }
  var presentationOwner: UUID?

  // Подключает остановку для камеры, реакцию на готовность или ошибку и остановку при уходе
  // приложения в фон. Все эти события ведут через одного владельца просмотра.
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
  // Сверяет изменения строки с текущим файлом и видом сообщения. Останавливает просмотр, если
  // новый снимок убрал или заменил исходник.
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
  // Закрывает предыдущий просмотр, проверяет тип и получает источник в фоне. Сверяет номер
  // попытки и закрывает опоздавший файл, чтобы он не начал играть после другого выбора.
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
  // Запрашивает право после возврата старого, затем подключает источник и сохранённое время. При
  // позднем ответе возвращает полученное право вместо открытия чужого просмотра.
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
  // Дожидается готовности, перематывает и только затем подключает слой и запускает просмотр по
  // просьбе экрана. Так временный кадр остаётся до нужной позиции.
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
  // Сохраняет время и пиксели готового текущего видео. Во время восстановления прежнее место не
  // должно затереться нулём.
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
  // Снимает предыдущий слой, сохраняет новый и подключает проигрыватель при допустимом состоянии.
  // Два экрана не должны одновременно выводить один сеанс.
  func attach(output layer: AVPlayerLayer) {
    if output !== layer { output?.player = nil }
    output = layer
    bindPlayerToOutput()
  }
  // На время восстановления оставляет слой без проигрывателя. Поверхность может продолжать
  // показывать сохранённый кадр до конца перемотки.
  private func bindPlayerToOutput() {
    guard let output else { return }
    // Пока идёт перемотка, поверхность продолжает показывать сохранённый кадр.
    let player: AVPlayer? = restoringSavedPosition ? nil : session.player
    if output.player !== player { output.player = player }
  }
  // Снимает проигрыватель с переданного слоя. Очищает общую ссылку только если снят именно
  // текущий вывод.
  func detach(output layer: AVPlayerLayer) {
    layer.player = nil
    if output === layer { output = nil }
  }
  // Сбрасывает намерение продолжать, останавливает ролик и сохраняет просмотр. Обновляет экран,
  // чтобы тот сразу показал паузу.
  func pause() {
    wantsPlaying = false
    session.player.pause()
    rememberPlayback()
    notify()
  }
  // Помнит намерение продолжать и ждёт допустимого сеанса. Если ролик почти закончился, сначала
  // переносит позицию к началу.
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
  // Запускает готовый ролик обычным способом или без ожидания буфера по запросу экрана. После
  // запуска сообщает новое состояние.
  private func resumeReadyPlayer(immediately: Bool) {
    if immediately {
      session.player.playImmediately(atRate: 1)
    } else {
      session.player.play()
    }
    notify()
  }
  // Держит выбранное время между нулём и длиной ролика, затем просит перемотку. Полоса не должна
  // отправить проигрывателю время вне файла.
  func seek(ms: Int64, completion: @escaping (Bool) -> Void = { _ in }) {
    session.seek(ms: min(max(0, ms), max(0, durationMs)), completion: completion)
  }
  // Запоминает место, снимает ожидание источника и права, закрывает вывод и сеанс. Только после
  // возврата права сообщает о завершённой остановке.
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
  // Оповещает экран и копию списка подписчиков. Подписчик может уйти во время обновления, не
  // нарушив обход.
  private func notify() {
    onChange?()
    if !changeObservers.isEmpty { for action in Array(changeObservers.values) { action() } }
  }
  /// После закрытия новые запросы воспроизведения не принимаются.
  // Закрывает сеанс и удаляет подписки и системных наблюдателей. Позднее событие уже не обновляет
  // закрытый просмотр.
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
