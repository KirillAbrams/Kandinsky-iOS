import XCTest

@testable import Kandinsky

/// Сохраняет строку вызывающего места, чтобы отказ указывал на исходное ожидание.
private func check(_ value: @autoclosure () -> Bool, _ line: Int = #line) {
  XCTAssertTrue(value(), "source assertion", line: UInt(line))
}
private typealias Frame = FrameProbe
final class MediaSurfaceMailboxTests: XCTestCase {
  func testSourceOwnershipContract() {
    do {
      var queue: [() -> Void] = []
      let owner = MediaSurfaceMailbox<Frame>(schedule: { queue.append($0) }) { _ in }
      for _ in 0..<1000 {
        _ = owner.begin()
        owner.flush()
        owner.clear()
        owner.flush()
      }
      check(queue.count == 1)
      owner.close()
      while !queue.isEmpty { queue.removeFirst()() }
    }
    var tasks: [() -> Void] = []
    var shown = -1
    let box = MediaSurfaceMailbox<Frame>(schedule: { tasks.append($0) }) { shown = $0?.value ?? -1 }
    let token = box.begin()!
    let frames = (1...1000).map(Frame.init)
    for frame in frames { check(box.offer(frame, binding: token, sequence: UInt64(frame.value))) }
    check(tasks.count == 1 && frames.filter { $0.closes == 1 }.count == 999)
    tasks.removeFirst()()
    check(shown == 1000)
    let duplicate = Frame(0)
    check(!box.offer(duplicate, binding: token, sequence: 1000) && duplicate.closes == 1)
    let next = box.begin()!
    let late = Frame(9)
    check(!box.offer(late, binding: token, sequence: 1001) && late.closes == 1)
    let current = Frame(8)
    check(box.offer(current, binding: next, sequence: 1))
    tasks.removeFirst()()
    check(shown == 8 && frames.last!.closes == 1)
    let pending = Frame(10)
    check(box.offer(pending, binding: next, sequence: 2))
    box.close()
    check(pending.closes == 1 && current.closes == 0)
    box.flush()
    check(shown == -1 && current.closes == 1 && box.begin() == nil)
    while !tasks.isEmpty { tasks.removeFirst()() }
    check(shown == -1 && current.closes == 1)

  }
  func testConcurrentOfferAndCloseReleaseExactlyOnce() {
    for _ in 0..<100 {
      var tasks: [() -> Void] = []
      let box = MediaSurfaceMailbox<FrameProbe>(schedule: { tasks.append($0) }) { _ in }
      let token = box.begin()!
      let frame = FrameProbe(1)
      let start = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        start.wait()
        box.offer(frame, binding: token, sequence: 1)
        done.signal()
      }
      start.signal()
      box.close()
      box.flush()
      XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
      while !tasks.isEmpty { tasks.removeFirst()() }
      XCTAssertEqual(frame.closes, 1)
    }
  }
}
