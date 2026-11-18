// Загружает с сервера ограниченные отрезки медиа для воспроизведения. Проверяет границы каждого
// ответа, чтобы сервер по ошибке не прислал в память весь файл.

import Foundation

final class MediaRangeHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private final class Read {
    let ready = DispatchSemaphore(value: 0), expected: String, maximum: Int
    var bytes = Data(), error: Error?
    // Создаёт очередь ожидания для одного отрезка и заранее оставляет место под известное число
    // байтов. Ожидаемые границы пригодятся при проверке ответа.
    init(expected: String, maximum: Int) {
      self.expected = expected
      self.maximum = maximum
      bytes.reserveCapacity(maximum)
    }
  }
  private let gate = NSLock()
  private var reads: [Int: Read] = [:]
  private var session: URLSession!
  private let finished: (@Sendable () -> Void)?
  /// Общее хранение ответов и сетевых записей входа отключено, поскольку готовыми байтами управляет
  /// собственное хранилище медиа.
  // Создаёт отдельное сетевое соединение без общего хранения ответов и записей входа.
  // Ограничивает число подключений, время ожидания и выполняет ответы последовательно, чтобы
  // отрезки не перегружали загрузку.
  init(finished: (@Sendable () -> Void)? = nil) {
    self.finished = finished
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 2
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    config.urlCache = nil
    config.httpCookieStorage = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "Kandinsky bounded ranges"
    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }
  // Читает отрезок вне потока экрана, добавляет обработчик отмены и ждёт результат с пределом по
  // времени. Принимает байты только нужной длины, иначе проигрыватель получил бы обрыв как целый
  // отрезок.
  func read(_ request: URLRequest, expected: String, count: Int, token: MediaCancellation) throws
    -> Data
  {
    precondition(!Thread.isMainThread)
    guard (1...MediaRangeCache.chunkSize).contains(count), !token.isCancelled else {
      throw MediaError.cancelled
    }
    let pending = Read(expected: expected, maximum: count), task = session.dataTask(with: request)
    gate.lock()
    reads[task.taskIdentifier] = pending
    gate.unlock()
    token.onCancel { task.cancel() }
    if token.isCancelled { task.cancel() }
    task.resume()
    guard pending.ready.wait(timeout: .now() + 35) == .success else {
      task.cancel()
      throw MediaError.io
    }
    if token.isCancelled { throw MediaError.cancelled }
    if let error = pending.error { throw error }
    guard pending.bytes.count == count else { throw MediaError.corrupt }
    return pending.bytes
  }
  /// При отличии сохраняет причину отказа и отменяет приём, чтобы целый файл не попал в память этого чтения.
  // Сверяет, что ответ содержит именно запрошенный отрезок и объявляет верную длину. При отличии
  // запоминает причину и останавливает приём до попадания лишних данных в память.
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    gate.lock()
    let read = reads[dataTask.taskIdentifier]
    gate.unlock()
    guard let read, let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    guard http.statusCode == 206 else {
      gate.lock()
      read.error = NetworkFailure(status: http.statusCode, code: "media_range")
      gate.unlock()
      completionHandler(.cancel)
      return
    }
    guard http.value(forHTTPHeaderField: "Content-Range") == read.expected,
      (http.expectedContentLength < 0 || http.expectedContentLength == Int64(read.maximum))
    else {
      gate.lock()
      read.error = MediaError.corrupt
      gate.unlock()
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
  // Добавляет очередную порцию байтов под защитой от одновременных записей. При превышении
  // ожидаемого размера прерывает загрузку, чтобы буфер не рос дальше.
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    gate.lock()
    defer { gate.unlock() }
    guard let read = reads[dataTask.taskIdentifier] else { return }
    if read.bytes.count + data.count > read.maximum {
      read.error = MediaError.corrupt
      dataTask.cancel()
    } else {
      read.bytes.append(data)
    }
  }
  // Забирает законченную операцию из списка, сохраняет первую причину ошибки и будит ожидающее
  // чтение. Иначе оно продолжало бы ждать уже остановленную передачу.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    gate.lock()
    let read = reads.removeValue(forKey: task.taskIdentifier)
    gate.unlock()
    guard let read else { return }
    if read.error == nil { read.error = error }
    read.ready.signal()
  }
  // Отказывает в переадресации отрезка. Без этого запрос с временным правом на скачивание мог бы
  // уйти на другой адрес.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
  // Сообщает вызывающему коду, что собраны сведения о завершённой сетевой операции. Сигнал нужен
  // для учёта сетевой работы.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) { finished?() }
  // Останавливает соединение и его запросы при закрытии владельца. Иначе незаконченные чтения
  // продолжили бы держать соединения.
  func close() { session.invalidateAndCancel() }
}
