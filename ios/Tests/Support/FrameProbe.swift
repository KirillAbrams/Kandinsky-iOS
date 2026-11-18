// Даём проверкам простой объект с номером и счётчиком освобождения. По нему видно, вернули ли
// занятую память ровно один раз.

import XCTest
@testable import Kandinsky
final class FrameProbe: MediaSurfacePayload {
  let value: Int
  private let lock = NSLock()
  private var count = 0
  var closes: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  // Сохраняем номер, по которому проверка отличает кадры. Номер остаётся неизменным при передаче
  // объекта между владельцами.
  init(_ value: Int) { self.value = value }
  // Под защитой прибавляем вызов к счётчику и сразу требуем единицу. Повторное освобождение
  // обнаруживается в месте вызова.
  func close() {
    lock.lock()
    count += 1
    XCTAssertEqual(count, 1)
    lock.unlock()
  }
}
