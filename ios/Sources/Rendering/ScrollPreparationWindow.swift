import Foundation

struct ScrollPreparationWindow {
  private(set) var before = 500.0, after = 500.0
  private(set) var mediaBefore = 500.0, mediaAfter = 320.0
  private var offset: Double?, timestamp: Double?

  mutating func observe(offset next: Double, at now: Double, viewport: Double) {
    guard next.isFinite, now.isFinite, viewport.isFinite, viewport > 0 else { return }
    let mediaCeiling = min(4096, viewport * 3)
    mediaBefore = min(mediaBefore, mediaCeiling)
    mediaAfter = min(mediaAfter, mediaCeiling)
    guard let offset, let timestamp else {
      self.offset = next
      self.timestamp = now
      return
    }
    let elapsed = now - timestamp
    // Несколько системных вызовов могут относиться к одному поступлению жеста.
    guard elapsed >= 1.0 / 240 else { return }
    defer {
      self.offset = next
      self.timestamp = now
    }
    guard elapsed <= 0.25 else {
      before = 500
      after = 500
      mediaBefore = min(500, mediaCeiling)
      mediaAfter = min(320, viewport * 0.4)
      return
    }
    let delta = next - offset
    guard abs(delta) > 0.01 else { return }
    let ceiling = max(500, min(6144, viewport * 8))
    let runway = min(ceiling, max(500, 500 + abs(delta) / elapsed * (4.0 / 60)))
    // Сеть получает больше времени, чем подготовка текста, но не уходит дальше трёх экранов.
    let mediaLead = min(mediaCeiling, 500 + abs(delta) / elapsed * 0.35)
    let mediaTrail = min(320, viewport * 0.4)
    if delta < 0 {
      before = min(ceiling, max(runway, before * 0.9))
      after = 500
      mediaBefore = mediaLead
      mediaAfter = mediaTrail
    } else {
      after = min(ceiling, max(runway, after * 0.9))
      before = 500
      mediaBefore = mediaTrail
      mediaAfter = mediaLead
    }
  }

  mutating func rebase(by delta: Double) {
    guard delta.isFinite else { return }
    if let offset { self.offset = offset + delta }
  }
  mutating func reset() {
    before = 500
    after = 500
    mediaBefore = 500
    mediaAfter = 320
    offset = nil
    timestamp = nil
  }
}
