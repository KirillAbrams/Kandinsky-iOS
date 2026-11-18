import Foundation
import AVFoundation
import UniformTypeIdentifiers

final class MediaPlaybackSource: @unchecked Sendable {
  let asset: AVURLAsset
  let localFile: URL?
  private let resource: RangeAssetLoader?
  private let gate = NSLock()
  private var onClose: (() -> Void)?
  /// Запоминает действие, которое снимет удержание файла после закрытия проигрывателя.
  init(file: URL, onClose: @escaping () -> Void = {}) {
    self.onClose = onClose
    asset = AVURLAsset(url: file)
    localFile = file
    resource = nil
  }
  init(cache: MediaRangeCache, mime: String, blob: String, onClose: @escaping () -> Void = {}) {
    self.onClose = onClose
    asset = AVURLAsset(url: URL(string: "kandinsky-media://object/" + blob)!)
    localFile = nil
    let loader = RangeAssetLoader(cache: cache, mime: mime)
    resource = loader
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
  }
  /// Забирает действие освобождения под блокировкой и сразу очищает его, чтобы повторное закрытие не вызвало
  /// его второй раз.
  func close() {
    gate.lock()
    let release = onClose
    onClose = nil
    gate.unlock()
    resource?.close()
    release?()
  }
  func prepareForPlayback(_ token: MediaCancellation) throws {
    try resource?.prepareForPlayback(token)
  }
  /// Закрывает источник, если его владелец не успел сделать это явно.
  deinit { close() }
}

private final class RangeAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  final class Job {
    let request: AVAssetResourceLoadingRequest, token = MediaCancellation()
    var offset: Int64 = 0, end: Int64 = 0
    init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
  }
  let queue = DispatchQueue(label: "dev.kirill.kandinsky.media.asset-loader")
  private let worker = DispatchQueue(
    label: "dev.kirill.kandinsky.media.range-read", qos: .userInitiated)
  private let cache: MediaRangeCache, mime: String
  private var jobs: [ObjectIdentifier: Job] = [:], closed = false
  init(cache: MediaRangeCache, mime: String) {
    self.cache = cache
    self.mime = mime
  }
  func prepareForPlayback(_ token: MediaCancellation) throws {
    let chunk = Int64(MediaRangeCache.chunkSize)
    let offsets = [Int64(0), chunk, (cache.length - 1) / chunk * chunk]
    var visited = Set<Int64>()
    for offset in offsets where offset < cache.length && visited.insert(offset).inserted {
      _ = try cache.read(offset: offset, count: 1, cancellation: token)
    }
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard !closed, jobs.count < 8 else {
      request.finishLoading(with: MediaError.unavailable)
      return true
    }
    if let content = request.contentInformationRequest {
      content.contentType = UTType(mimeType: mime)?.identifier
      content.contentLength = cache.length
      content.isByteRangeAccessSupported = true
    }
    guard let data = request.dataRequest else {
      request.finishLoading()
      return true
    }
    let job = Job(request)
    job.offset = max(data.currentOffset, data.requestedOffset)
    guard job.offset >= 0, job.offset <= cache.length, data.requestedLength >= 0 else {
      request.finishLoading(with: MediaError.corrupt)
      return true
    }
    job.end =
      data.requestsAllDataToEndOfResource
      ? cache.length
      : data.requestedOffset + min(Int64(data.requestedLength), cache.length - data.requestedOffset)
    jobs[ObjectIdentifier(request)] = job
    next(job)
    return true
  }
  private func next(_ job: Job) {
    let id = ObjectIdentifier(job.request)
    guard !closed, jobs[id] === job, !job.token.isCancelled else { return }
    if job.offset >= job.end {
      jobs.removeValue(forKey: id)
      _ = job.token.finish()
      job.request.finishLoading()
      return
    }
    let offset = job.offset, count = Int(min(65536, job.end - offset))
    worker.async { [self] in
      let result = Result { try cache.read(offset: offset, count: count, cancellation: job.token) }
      queue.async { [self] in
        guard !closed, jobs[id] === job, !job.token.isCancelled else { return }
        switch result {
        case let .success(bytes):
          guard !bytes.isEmpty else {
            jobs.removeValue(forKey: id)
            job.request.finishLoading(with: MediaError.corrupt)
            return
          }
          job.request.dataRequest?.respond(with: bytes)
          job.offset += Int64(bytes.count)
          next(job)
        case let .failure(error):
          jobs.removeValue(forKey: id)
          job.request.finishLoading(with: error)
        }
      }
    }
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
  ) { jobs.removeValue(forKey: ObjectIdentifier(request))?.token.cancel() }
  /// Каждый ожидающий запрос получает завершение с отменой, чтобы проигрыватель не продолжал ждать байты
  /// после закрытия.
  func close() {
    cache.close()
    queue.async { [self] in
      guard !closed else { return }
      closed = true
      let pending = Array(jobs.values)
      jobs.removeAll()
      for job in pending {
        job.token.cancel()
        job.request.finishLoading(with: MediaError.cancelled)
      }
    }
  }
}
