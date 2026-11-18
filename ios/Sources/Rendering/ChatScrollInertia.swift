// Инерция ленты на айфоне рассчитывает затухание и передаёт видимое движение графическому слою.
// Лента готовит содержимое по видимому положению, даже если системная область уже стоит в
// конечной точке. При касании движение возвращается под палец.

import UIKit
import UIKit.UIGestureRecognizerSubclass

struct ChatInertiaTrajectory {
  let start: CGFloat
  let destination: CGFloat
  let duration: TimeInterval
  let logDecay: Double

  // Принимаем конечные координаты и пригодную скорость, затем вычисляем ограниченную длительность
  // затухания. Почти остановившийся или слишком короткий жест остаётся у обычной прокрутки.
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

  // Строим уже рассчитанный путь с указанным временем и затуханием. Это нужно для переноса и
  // сокращения пути без повторной оценки скорости.
  private init(start: CGFloat, destination: CGFloat, duration: TimeInterval, logDecay: Double) {
    self.start = start
    self.destination = destination
    self.duration = duration
    self.logDecay = logDecay
  }

  // Переводим прошедшее время в видимую координату на пути. По ней лента решает, какие строки уже
  // надо подготовить.
  func offset(at elapsed: TimeInterval) -> CGFloat {
    start + (destination - start) * progress(at: elapsed)
  }

  // Ограничиваем время началом и концом, затем считаем долю затухающего движения. При отпускании
  // путь идёт быстрее, а перед остановкой замедляется.
  private func progress(at elapsed: TimeInterval) -> CGFloat {
    let time = min(max(0, elapsed), duration)
    return CGFloat(expm1(logDecay * time) / expm1(logDecay * duration))
  }

  // Сдвигаем начало и конец на одинаковое расстояние. Такой перенос меняет геометрию, сохраняя
  // скорость и длительность.
  func translated(by shift: CGFloat) -> Self {
    Self(start: start + shift, destination: destination + shift,
      duration: duration, logDecay: logDecay)
  }

  // Укорачиваем путь до выбранного момента внутри движения. Если время уже вне пути, отдельное
  // торможение не нужно.
  func stopping(at elapsed: TimeInterval) -> Self? {
    guard elapsed > 0, elapsed < duration else { return nil }
    return Self(start: start, destination: offset(at: elapsed), duration: elapsed, logDecay: logDecay)
  }

  // Строим добавочные положения слоя по долям времени. Основная область уже находится в конце
  // пути, а добавка ставит готовые строки под палец при отпускании.
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

  // Тормозим при первом касании и сразу уступаем распознавание другим жестам. Так новое нажатие
  // может открыть кнопку или начать прокрутку без ожидания этого наблюдателя.
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    host?.interruptCompositorFlight(braking: true)
    state = .failed
  }
}

extension ChatScrollHost {
  private static let compositorAnimationKey = "chat.compositorInertia"

  // Считаем крайние положения системной прокрутки с текущими отступами.
  private var offsetLimits: ClosedRange<CGFloat> {
    let start = -adjustedContentInset.top
    let end = max(start, contentSize.height - bounds.height + adjustedContentInset.bottom)
    return start...end
  }

  // Оставляем стандартное движение при озвучивании, управлении переключателями или уменьшении
  // движения.
  var usesCompositorInertia: Bool {
    canUseCompositorInertia && !UIAccessibility.isVoiceOverRunning
      && !UIAccessibility.isSwitchControlRunning && !UIAccessibility.isReduceMotionEnabled
  }

  // Берём положение, видимое во время инерции, иначе системную координату истории.
  var viewportOffsetY: CGFloat { compositorFlight?.visibleOffset ?? contentOffset.y }

  // Диагностика читает фактический показанный слой и учитывает его добавочное смещение.
  var presentedViewportOffsetY: CGFloat? {
    guard let bounds = layer.presentation()?.bounds else { return nil }
    guard compositorFlight != nil || plane.layer.animation(forKey: Self.compositorAnimationKey) != nil
    else { return bounds.origin.y }
    guard let presentedPlane = plane.layer.presentation() else { return nil }
    return bounds.origin.y - (presentedPlane.position.y - plane.layer.position.y)
  }

  // Оставляем только подходящее вертикальное движение внутри границ. Если путь принят, удерживаем
  // системную цель у места отпускания, чтобы система не запустила вторую инерцию.
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

  // Забираем подготовленный путь и запоминаем время начала. Удаляем старую точку чтения и
  // запускаем графический слой вместе с подготовкой кадров.
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

  // Переносим основную область в расчётную конечную позицию без системной анимации. При старте
  // ставим отдельное смещение слоя, а внутренний признак защищает от повторной обработки события.
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

  // Вычисляем видимое положение на время кадра и направляем запас подготовки в сторону движения.
  // При конце или изменении настроек доступности завершаем путь.
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

  // Переносим траекторию при уточнении высот строк без перезапуска её формы. Если новый конец
  // вышел за допустимую область, прекращаем инерцию на восстановленной координате.
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

  // Сбрасываем ожидающий старт и останавливаем видимое движение. При первом касании учитываем
  // время до ближайшего показа, чтобы область не перескочила к более раннему кадру.
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

  // Передаём вычисленную видимую точку обратно обычной прокрутке и снимаем анимацию или её
  // остаток после торможения. В конце сохраняем чтение либо только останавливаем измерение.
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
