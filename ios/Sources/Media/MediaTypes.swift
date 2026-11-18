import Foundation
enum MediaError: Error, Equatable, Sendable {
  case unavailable, permissionDenied, interrupted, corrupt, storageFull, io, cancelled
}
enum CaptureKind: Sendable { case photo }
struct ThumbnailKey: Hashable, Sendable {
  var maxPixel: Int = 1024
  var studioOriginal = false
  var gallery = false
}
protocol MediaFileProvider: AnyObject, Sendable {
  func cached(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws -> (
    URL, String
  )?
  func resolve(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws -> (
    URL, String
  )
}
final class MediaCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var state = 0
  private var handler: (() -> Void)?
  private var progress: ((Double) -> Void)?
  /// После отмены или завершения новый обработчик не устанавливается.
  func onProgress(_ action: @escaping (Double) -> Void) {
    lock.lock()
    if state == 0 { progress = action }
    lock.unlock()
  }
  func reportProgress(_ value: Double) {
    lock.lock()
    let action = state == 0 ? progress : nil
    lock.unlock()
    action?(min(1, max(0, value)))
  }
  func onCancel(_ action: @escaping () -> Void) {
    lock.lock()
    let now = state == 1
    if state == 0 { handler = action }
    lock.unlock()
    if now { action() }
  }
  /// Сохранённое действие вызывает вне защиты состояния, чтобы оно могло завершить связанную работу.
  func cancel() {
    lock.lock()
    guard state == 0 else {
      lock.unlock()
      return
    }
    state = 1
    let action = handler
    handler = nil
    progress = nil
    lock.unlock()
    action?()
  }
  /// Очищает обработчики, чтобы они не удерживали получателей после конца работы.
  func finish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == 0 else { return false }
    state = 2
    handler = nil
    progress = nil
    return true
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == 1
  }
}
final class CaptureLease {
  let kind: CaptureKind
  private let lock = NSLock()
  private var action: (() -> Void)?
  init(kind: CaptureKind, release: @escaping () -> Void) {
    self.kind = kind
    action = release
  }
  func release() {
    lock.lock()
    let work = action
    action = nil
    lock.unlock()
    work?()
  }
}
final class PlaybackLease {
  private let lock = NSLock()
  private var action: (() -> Void)?
  init(release: @escaping () -> Void) { action = release }
  func release() {
    lock.lock()
    let work = action
    action = nil
    lock.unlock()
    work?()
  }
}
@MainActor protocol CaptureAdmission: AnyObject {
  @discardableResult func acquire(
    _ kind: CaptureKind, completion: @escaping (Result<CaptureLease, Error>) -> Void
  ) -> MediaCancellation
}
