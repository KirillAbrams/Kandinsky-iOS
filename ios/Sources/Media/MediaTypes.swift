// Задаёт общие ошибки, форму запроса изображения, сигналы отмены и право на камеру или
// проигрывание. Эти правила связывают экран и фоновую работу.

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
  // Задаёт поиск уже сохранённого файла без новой сетевой загрузки. Это помогает показать готовое
  // вложение сразу.
  func cached(_ attachment: Attachment, preview: Bool, token: MediaCancellation) throws -> (
    URL, String
  )?
  // Задаёт получение пригодного файла и его типа, при необходимости через сеть. Запрос может быть
  // отменён владельцем экрана.
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
  // Запоминает обработчик хода только для активной работы. Законченный запрос не должен
  // удерживать новый экран.
  func onProgress(_ action: @escaping (Double) -> Void) {
    lock.lock()
    if state == 0 { progress = action }
    lock.unlock()
  }
  // Забирает текущий обработчик и ограничивает долю от нуля до единицы. После завершения
  // сохранённый экран не получает новые значения.
  func reportProgress(_ value: Double) {
    lock.lock()
    let action = state == 0 ? progress : nil
    lock.unlock()
    action?(min(1, max(0, value)))
  }
  // Назначает действие для активной отмены. Если отмена уже произошла, выполняет действие сразу,
  // чтобы поздно начатая передача успела остановиться.
  func onCancel(_ action: @escaping () -> Void) {
    lock.lock()
    let now = state == 1
    if state == 0 { handler = action }
    lock.unlock()
    if now { action() }
  }
  /// Сохранённое действие вызывает вне защиты состояния, чтобы оно могло завершить связанную работу.
  // Один раз отмечает отмену и убирает обработчики под блокировкой. Вызывает действие уже без
  // блокировки, чтобы оно могло закрыть собственные ресурсы.
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
  // Отмечает успешный конец активной работы и снимает обработчики. Возвращает отказ, если работа
  // уже была отменена или завершена.
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
  // Запоминает вид съёмки и действие освобождения камеры. Право возвращается владельцу очереди
  // после ухода экрана съёмки.
  init(kind: CaptureKind, release: @escaping () -> Void) {
    self.kind = kind
    action = release
  }
  // Забирает действие возврата камеры единожды и вызывает вне блокировки. Повторное закрытие не
  // освободит место чужой съёмки.
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
  // Запоминает действие освобождения места проигрывания. Оно пригодится при выходе из просмотра.
  init(release: @escaping () -> Void) { action = release }
  // Возвращает место проигрывания только одним вызовом. Без этого повторное закрытие могло бы
  // нарушить счёт занятых мест.
  func release() {
    lock.lock()
    let work = action
    action = nil
    lock.unlock()
    work?()
  }
}
@MainActor protocol CaptureAdmission: AnyObject {
  // Задаёт запрос на право съёмки с отложенным ответом и возможностью отмены. Ожидающий экран
  // может уйти ещё до выдачи камеры.
  @discardableResult func acquire(
    _ kind: CaptureKind, completion: @escaping (Result<CaptureLease, Error>) -> Void
  ) -> MediaCancellation
}
