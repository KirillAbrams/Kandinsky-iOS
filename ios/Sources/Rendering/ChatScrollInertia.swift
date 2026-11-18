import UIKit
import UIKit.UIGestureRecognizerSubclass

struct ChatInertiaTrajectory {
  let start: CGFloat
  let destination: CGFloat
  let duration: TimeInterval
  let logDecay: Double

  init?(start: CGFloat, destination: CGFloat, velocity: CGFloat, decay: CGFloat) {
    let speed = abs(Double(velocity))
    guard start.isFinite, destination.isFinite, speed.isFinite,
      abs(destination - start) >= 16, speed >= 0.08, decay > 0, decay < 1
    else { return nil }
    self.start = start
    self.destination = destination
    logDecay = log(Double(decay)) * 1000
    duration = min(3.6, max(0.18, log(0.02 / speed) / logDecay))
  }

  private init(start: CGFloat, destination: CGFloat, duration: TimeInterval, logDecay: Double) {
    self.start = start
    self.destination = destination
    self.duration = duration
    self.logDecay = logDecay
  }

  func offset(at elapsed: TimeInterval) -> CGFloat {
    start + (destination - start) * progress(at: elapsed)
  }

  private func progress(at elapsed: TimeInterval) -> CGFloat {
    let time = min(max(0, elapsed), duration)
    return CGFloat(expm1(logDecay * time) / expm1(logDecay * duration))
  }

  func translated(by shift: CGFloat) -> Self {
    Self(start: start + shift, destination: destination + shift,
      duration: duration, logDecay: logDecay)
  }

  func stopping(at elapsed: TimeInterval) -> Self? {
    guard elapsed > 0, elapsed < duration else { return nil }
    return Self(start: start, destination: offset(at: elapsed), duration: elapsed, logDecay: logDecay)
  }

  @MainActor func animation(
    for layer: CALayer, startTime: TimeInterval, modelDestination: CGFloat
  ) -> CAKeyframeAnimation {
    let count = Int(ceil(duration * 120))
    let fractions = (0...count).map { Double($0) / Double(count) }
    let animation = CAKeyframeAnimation(keyPath: "position.y")
    // Само окно уже находится в конечной позиции. Добавка возвращает видимые строки к месту отпускания.
    animation.isAdditive = true
    let travel = modelDestination - start
    animation.values = fractions.map { NSNumber(value: Double(travel * (1 - progress(at: $0 * duration)))) }
    animation.keyTimes = fractions.map { NSNumber(value: $0) }
    animation.calculationMode = .linear
    animation.duration = duration
    animation.beginTime = layer.convertTime(startTime, from: nil)
    return animation
  }
}

struct ChatInertiaFlight {
  let startedAt: TimeInterval
  var trajectory: ChatInertiaTrajectory
  var visibleOffset: CGFloat
  var sampledAt: TimeInterval
}

@MainActor final class ChatInertiaTouch: UIGestureRecognizer {
  weak var host: ChatScrollHost?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    host?.interruptCompositorFlight(braking: true)
    state = .failed
  }
}

extension ChatScrollHost {
  private static let compositorAnimationKey = "chat.compositorInertia"

  private var offsetLimits: ClosedRange<CGFloat> {
    let start = -adjustedContentInset.top
    let end = max(start, contentSize.height - bounds.height + adjustedContentInset.bottom)
    return start...end
  }

  var usesCompositorInertia: Bool {
    canUseCompositorInertia && !UIAccessibility.isVoiceOverRunning
      && !UIAccessibility.isSwitchControlRunning && !UIAccessibility.isReduceMotionEnabled
  }

  var viewportOffsetY: CGFloat { compositorFlight?.visibleOffset ?? contentOffset.y }

  var presentedViewportOffsetY: CGFloat? {
    guard let bounds = layer.presentation()?.bounds else { return nil }
    guard compositorFlight != nil || plane.layer.animation(forKey: Self.compositorAnimationKey) != nil
    else { return bounds.origin.y }
    guard let presentedPlane = plane.layer.presentation() else { return nil }
    return bounds.origin.y - (presentedPlane.position.y - plane.layer.position.y)
  }

  func prepareCompositorFlight(velocity: CGPoint, target: UnsafeMutablePointer<CGPoint>) {
    pendingCompositorTrajectory = nil
    guard usesCompositorInertia, !closed, abs(velocity.y) >= abs(velocity.x) else { return }
    let limits = offsetLimits
    let start = contentOffset.y
    let end = target.pointee.y
    guard limits.contains(start), end > limits.lowerBound + 1, end < limits.upperBound - 1,
      let trajectory = ChatInertiaTrajectory(
        start: start, destination: end, velocity: velocity.y, decay: decelerationRate.rawValue)
    else { return }
    pendingCompositorTrajectory = trajectory
    target.pointee = contentOffset
  }

  func beginCompositorFlight() -> Bool {
    guard let trajectory = pendingCompositorTrajectory else { return false }
    pendingCompositorTrajectory = nil
    guard !closed else { return false }
    let now = scrollClock()
    let flight = ChatInertiaFlight(
      startedAt: now, trajectory: trajectory, visibleOffset: trajectory.start, sampledAt: now)
    pendingAnchor = nil
    applyCompositorFlight(flight, starting: true)
    schedule()
    return true
  }

  private func applyCompositorFlight(_ flight: ChatInertiaFlight, starting: Bool) {
    let wasApplying = applying
    applying = true
    compositorFlight = flight
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    setContentOffset(CGPoint(x: contentOffset.x, y: flight.trajectory.destination), animated: false)
    if starting {
      plane.layer.add(
        flight.trajectory.animation(
          for: plane.layer, startTime: flight.startedAt, modelDestination: contentOffset.y),
        forKey: Self.compositorAnimationKey)
    }
    CATransaction.commit()
    applying = wasApplying
  }

  func sampleCompositorFlight(at timestamp: TimeInterval) {
    guard var flight = compositorFlight else { return }
    if !usesCompositorInertia {
      interruptCompositorFlight()
      return
    }
    if timestamp - flight.startedAt >= flight.trajectory.duration {
      finishCompositorFlight(at: flight.trajectory.destination)
      return
    }
    flight.sampledAt = timestamp
    flight.visibleOffset = flight.trajectory.offset(at: timestamp - flight.startedAt)
    compositorFlight = flight
    preparation.observe(offset: Double(flight.visibleOffset), at: timestamp,
      viewport: Double(bounds.height))
  }

  func rebaseCompositorFlight(to offset: CGFloat) {
    guard var flight = compositorFlight else { return }
    let shifted = flight.trajectory.translated(by: offset - flight.visibleOffset)
    guard offsetLimits.contains(shifted.destination) else {
      finishCompositorFlight(at: offset, settle: false)
      return
    }
    // Добавочные смещения при параллельном переносе не меняются. Оставляем прежнюю анимацию.
    flight.trajectory = shifted
    flight.visibleOffset = offset
    applyCompositorFlight(flight, starting: false)
  }

  func interruptCompositorFlight(braking: Bool = false) {
    pendingCompositorTrajectory = nil
    guard let flight = compositorFlight else {
      if !braking { plane.layer.removeAnimation(forKey: Self.compositorAnimationKey) }
      return
    }
    let now = max(scrollClock(), flight.sampledAt)
    if braking, usesCompositorInertia {
      let stop = compositorCatchTime(at: now) - flight.startedAt
      let brake = flight.trajectory.stopping(at: stop)
      finishCompositorFlight(at: brake?.destination ?? flight.trajectory.destination, brake: brake)
      return
    }
    let offset = flight.trajectory.offset(at: now - flight.startedAt)
    finishCompositorFlight(at: offset)
  }

  func finishCompositorFlight(
    at offset: CGFloat, settle: Bool = true, brake: ChatInertiaTrajectory? = nil
  ) {
    guard let flight = compositorFlight else {
      plane.layer.removeAnimation(forKey: Self.compositorAnimationKey)
      return
    }
    let wasApplying = applying
    applying = true
    compositorFlight = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    setContentOffset(CGPoint(x: contentOffset.x, y: offset), animated: false)
    if let brake {
      // Текущий кадр ещё движется до показа изменения. Продлеваем его по той же траектории.
      plane.layer.add(
        brake.animation(for: plane.layer, startTime: flight.startedAt, modelDestination: contentOffset.y),
        forKey: Self.compositorAnimationKey)
    } else {
      plane.layer.removeAnimation(forKey: Self.compositorAnimationKey)
    }
    CATransaction.commit()
    applying = wasApplying
    if settle {
      settleScrolling()
    } else {
      motionProbe.record(.didEndDecelerating)
      frameProbe.stop()
    }
  }
}
