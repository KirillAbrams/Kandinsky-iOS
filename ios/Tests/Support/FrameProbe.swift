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
  init(_ value: Int) { self.value = value }
  /// Требует единственный вызов, чтобы повторный возврат удержания сразу выявлялся проверкой.
  func close() {
    lock.lock()
    count += 1
    XCTAssertEqual(count, 1)
    lock.unlock()
  }
}
