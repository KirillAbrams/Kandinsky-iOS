// Передаёт экрану самый свежий кадр текущего источника. Старые кадры освобождаются, а несколько
// обновлений могут прийти на экран одним вызовом.

import Foundation

protocol MediaSurfacePayload: AnyObject {
  // Задаёт для любого кадра способ освободить занимаемый ресурс. Очередь вызывает его также для
  // кадров, которые оказались лишними ещё до показа.
  func close()
}

final class MediaSurfaceMailbox<Frame: MediaSurfacePayload> {
  private let lock = NSLock()
  private let schedule: (@escaping () -> Void) -> Void
  private var render: ((Frame?) -> Void)?
  private var binding: UInt64 = 0, sequence: UInt64 = 0
  private var active = false, closed = false, dirty = false, clearDisplay = false, scheduled = false
  private var pending: Frame?, displayed: Frame?
  /// Планировщик должен ставить задачу на потом, чтобы обработка не началась внутри изменения состояния.
  // Запоминает планировщик и действие показа. Планировщик должен вызвать обновление позже, чтобы
  // оно не началось внутри изменения кадра.
  init(
    schedule: @escaping (@escaping () -> Void) -> Void,
    render: @escaping (Frame?) -> Void
  ) {
    self.schedule = schedule
    self.render = render
  }
  // Выдаёт новый номер привязки и сбрасывает порядок кадров. Может сохранить уже показанный кадр
  // до замены, чтобы переход не оставил пустое место.
  func begin(preservingDisplay: Bool = false) -> UInt64? {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return nil
    }
    let token: UInt64?
    if binding == UInt64.max {
      closed = true
      active = false
      token = nil
    } else {
      binding += 1
      sequence = 0
      active = true
      token = binding
    }
    let old = pending
    pending = nil
    clearDisplay = !preservingDisplay || displayed == nil
    dirty = true
    let notify = markNotice()
    lock.unlock()
    old?.close()
    if notify { enqueueNotice() }
    return token
  }
  /// Заменённый или отклонённый кадр закрывает самостоятельно, поэтому владение передаётся даже при
  /// отказе.
  // Принимает более свежий кадр только от текущей привязки. Освобождает вытесненный или
  // отклонённый кадр, иначе быстрая смена источника удерживала бы лишние изображения.
  @discardableResult func offer(_ frame: Frame, binding token: UInt64, sequence serial: UInt64)
    -> Bool
  {
    lock.lock()
    let accepted = active && !closed && token == binding && serial > sequence
    let old: Frame?
    let notify: Bool
    if accepted {
      sequence = serial
      old = pending
      pending = frame
      dirty = true
      notify = markNotice()
    } else {
      old = frame
      notify = false
    }
    lock.unlock()
    old?.close()
    if notify { enqueueNotice() }
    return accepted
  }
  // Снимает текущую привязку и назначает очистку изображения. Очередь остаётся доступной для
  // следующего источника.
  func clear() { invalidate(terminal: false) }
  // Закрывает очередь окончательно и снимает изображение. Поздние кадры больше не могут начать
  // показ заново.
  func close() { invalidate(terminal: true) }

  // Меняет номер привязки, убирает ожидающий кадр и ставит очистку экрана. Это отделяет поздние
  // ответы от следующего источника.
  private func invalidate(terminal: Bool) {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = terminal || binding == UInt64.max
    if binding != UInt64.max { binding += 1 }
    active = false
    let old = pending
    pending = nil
    clearDisplay = true
    dirty = true
    let notify = markNotice()
    lock.unlock()
    old?.close()
    if notify { enqueueNotice() }
  }
  // Отмечает, что обновление уже назначено. Повторное предложение кадра заменяет содержимое без
  // ещё одной задачи в очереди.
  private func markNotice() -> Bool {
    if scheduled { return false }
    scheduled = true
    return true
  }
  // Передаёт отложенный вызов планировщику. Перед показом снимает отметку, чтобы следующий кадр
  // мог снова назначить обновление.
  private func enqueueNotice() {
    schedule { [self] in
      lock.lock()
      scheduled = false
      lock.unlock()
      flush()
    }
  }
  // При наличии изменений ставит готовый кадр на место показанного или очищает экран. Закрывает
  // снятый кадр после показа, чтобы тот оставался жив до замены.
  func flush() {
    lock.lock()
    guard dirty else {
      lock.unlock()
      return
    }
    dirty = false
    var old: Frame?
    if clearDisplay || pending != nil {
      old = displayed
      displayed = active && !closed ? pending : nil
      pending = nil
    }
    clearDisplay = false
    render?(displayed)
    if closed { render = nil }
    lock.unlock()
    old?.close()
  }
  // Освобождает оставшиеся кадры при уничтожении очереди. Это покрывает случай, когда планировщик
  // уже не сможет выполнить последнее обновление.
  deinit {
    pending?.close()
    displayed?.close()
  }
}
