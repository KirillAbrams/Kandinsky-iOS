import Foundation

protocol MediaSurfacePayload: AnyObject {
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
  init(
    schedule: @escaping (@escaping () -> Void) -> Void,
    render: @escaping (Frame?) -> Void
  ) {
    self.schedule = schedule
    self.render = render
  }
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
  func clear() { invalidate(terminal: false) }
  func close() { invalidate(terminal: true) }

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
  private func markNotice() -> Bool {
    if scheduled { return false }
    scheduled = true
    return true
  }
  private func enqueueNotice() {
    schedule { [self] in
      lock.lock()
      scheduled = false
      lock.unlock()
      flush()
    }
  }
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
  deinit {
    pending?.close()
    displayed?.close()
  }
}
