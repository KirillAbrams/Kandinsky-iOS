import Foundation
final class MediaDecodeQueue: @unchecked Sendable {
  private final class Job {
    enum State { case pending, running, done }
    let id = UUID(), token = MediaCancellation()
    var state = State.pending
    let execute: (Job) -> Void
    let fail: (Error) -> Void
    init(execute: @escaping (Job) -> Void, fail: @escaping (Error) -> Void) {
      self.execute = execute
      self.fail = fail
    }
  }
  private let gate = DispatchQueue(label: "dev.kirill.kandinsky.media.admission")
  private let workers = DispatchQueue(
    label: "dev.kirill.kandinsky.media.work", qos: .userInitiated, attributes: .concurrent)
  private var pending: [Job] = [], active: [UUID: Job] = [:]
  private var closed = false
  private let maximumWorkers: Int
  private let maximumPending: Int
  init(maximumWorkers: Int = 2, maximumPending: Int = 16) {
    precondition((1...2).contains(maximumWorkers))
    precondition((1...256).contains(maximumPending))
    self.maximumWorkers = maximumWorkers
    self.maximumPending = maximumPending
  }
  var runningCount: Int { gate.sync { active.count } }
  var pendingCount: Int { gate.sync { pending.count } }
  @discardableResult func submit<T>(
    priority: Int = 0, work: @escaping () throws -> T, dispose: @escaping (T) -> Void,
    completion: @escaping (Result<T, Error>) -> Void
  ) -> MediaCancellation {
    let job = Job(
      execute: { [self] job in
        let result: Result<T, Error> =
          job.token.isCancelled
          ? .failure(MediaError.cancelled) : Result { try autoreleasepool { try work() } }
        DispatchQueue.main.async {
          let allowed = self.gate.sync { !self.closed }
          if allowed && job.token.finish() {
            completion(result)
          } else {
            if case let .success(value) = result { dispose(value) }
            completion(.failure(MediaError.cancelled))
          }
          self.gate.async {
            job.state = .done
            self.active.removeValue(forKey: job.id)
            self.drain()
          }
        }
      }, fail: { completion(.failure($0)) })
    job.token.onCancel { [weak self, weak job] in
      guard let self, let job else { return }
      self.gate.async {
        if job.state == .pending, let i = self.pending.firstIndex(where: { $0.id == job.id }) {
          self.pending.remove(at: i)
          job.state = .done
          DispatchQueue.main.async { job.fail(MediaError.cancelled) }
        }
      }
    }
    gate.sync {
      if closed || (active.count >= maximumWorkers && pending.count >= maximumPending) {
        job.state = .done
        let error: MediaError = closed ? .cancelled : .unavailable
        DispatchQueue.main.async {
          let e: Error = job.token.finish() ? error : MediaError.cancelled
          job.fail(e)
        }
      } else {
        if priority > 0 { pending.insert(job, at: 0) } else { pending.append(job) }
        drain()
      }
    }
    return job.token
  }
  private func drain() {
    while !closed, active.count < maximumWorkers, !pending.isEmpty {
      let job = pending.removeFirst()
      if job.token.isCancelled {
        job.state = .done
        DispatchQueue.main.async { job.fail(MediaError.cancelled) }
        continue
      }
      job.state = .running
      active[job.id] = job
      workers.async { job.execute(job) }
    }
  }
  /// Активные задания тоже помечает отменёнными, чтобы поздний результат был освобождён.
  func close() {
    gate.sync {
      guard !closed else { return }
      closed = true
      let waiting = pending
      pending.removeAll()
      for job in waiting {
        job.state = .done
        job.token.cancel()
        DispatchQueue.main.async { job.fail(MediaError.cancelled) }
      }
      for job in active.values { job.token.cancel() }
    }
  }
}
