// Подготавливает запросы к серверу, открывает постоянную связь и передаёт файлы. Проверяет адрес,
// допустимый размер и целостность данных, чтобы закрытые сведения и вложения не ушли не туда.

import CryptoKit
import Foundation

struct NetworkFailure: Error {
  let status: Int
  let code: String
}
private final class NetworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
  private let finished: (@Sendable () -> Void)?
  // Запоминает необязательное действие после сбора сведений о запросе. Сетевой клиент может
  // учитывать завершённые передачи без участия экрана.
  init(finished: (@Sendable () -> Void)?) { self.finished = finished }
  // Передаёт сигнал о сборе сведений о завершившемся запросе. Этот сигнал относится к связи,
  // поэтому по нему нельзя считать генерацию законченной.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) { finished?() }
  // Отклоняет переход на другой адрес для обычных запросов. Так запрос с ключом доступа не
  // отправится вслед за перенаправлением.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
private final class MediaDownloadProgress: NSObject, URLSessionTaskDelegate {
  private let progress: @Sendable (Double) -> Void
  private let gate = NSRecursiveLock()
  private var observation: NSKeyValueObservation?
  private var lastUpdate: TimeInterval = -.infinity
  private var lastValue = 0.0
  private var stopped = false

  init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

  // Подписываемся до начала передачи. Доля считается по принятым байтам, а отметка о готовности
  // появится после проверки файла.
  func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
    observation = task.progress.observe(\.fractionCompleted) { [weak self, weak task] _, _ in
      guard let task, task.countOfBytesExpectedToReceive > 0 else { return }
      self?.report(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive))
    }
  }

  private func report(_ value: Double) {
    guard value > 0, value < 1 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    gate.withLock {
      guard !stopped, value > lastValue, now - lastUpdate >= 0.08 else { return }
      lastValue = value
      lastUpdate = now
      progress(value)
    }
  }

  func stop() { gate.withLock { stopped = true } }
}
private final class StudioUploadProgress: NSObject, URLSessionTaskDelegate {
  private let size: Int64
  private let progress: @Sendable (Double) -> Void
  private var last: TimeInterval = 0
  // Запоминает размер отправляемого файла и способ сообщать ход. Известная длина даёт делитель
  // даже при отсутствии сведений от сетевой службы.
  init(size: Int64, progress: @escaping @Sendable (Double) -> Void) {
    self.size = size
    self.progress = progress
  }
  // Считает долю отправленных байтов и сообщает её с ограничением частоты. В конце значение не
  // превышает полной передачи, даже если система насчитала больше байтов.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - last >= 0.08 || totalBytesSent >= size else { return }
    last = now
    progress(min(1, Double(totalBytesSent) / Double(size)))
  }
  // Отказывает в перенаправлении при отправке файла. Без этого исходник и заголовки запроса могли
  // бы уйти на другой адрес.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
final class NetworkAPI: @unchecked Sendable {
  @MainActor var onSessionRejected: ((String) -> Void)?
  private let profile: NetworkProfile?
  private let session: URLSession
  private let sourceSession: URLSession
  private let rangeHTTP: MediaRangeHTTP
  private let rangeObserved: (@Sendable (String, Int64, Int64, Int, Bool) -> Void)?
  // Создаёт соединения для обычных запросов, медленных исходников и чтения отрезков. У обычного
  // обмена короткое ожидание, а медленный исходник может передаваться дольше.
  init(
    profile: NetworkProfile?, onRequestFinished: (@Sendable () -> Void)? = nil,
    rangeObserved: (@Sendable (String, Int64, Int64, Int, Bool) -> Void)? = nil,
    transportConfiguration: URLSessionConfiguration? = nil
  ) {
    self.rangeObserved = rangeObserved
    self.profile = profile
    self.rangeHTTP = MediaRangeHTTP(finished: onRequestFinished)
    let config = transportConfiguration ?? Self.configuration(requestTimeout: 30, resourceTimeout: 90)
    let sourceConfig = Self.configuration(requestTimeout: 3600, resourceTimeout: 3600)
    let queue = OperationQueue()
    queue.name = "KandinskyHTTP"
    queue.maxConcurrentOperationCount = 2
    session = URLSession(
      configuration: config, delegate: NetworkRedirectPolicy(finished: onRequestFinished),
      delegateQueue: queue)
    // Передача по медленной сети может идти дольше обычного запроса списка чатов.
    sourceSession = URLSession(
      configuration: sourceConfig, delegate: NetworkRedirectPolicy(finished: onRequestFinished),
      delegateQueue: queue)
  }
  // Выбирает временное соединение без общего хранения ответов и записей входа. Ограничивает число
  // подключений и время ожидания, чтобы запросы не удерживали сеть без предела.
  private static func configuration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval)
    -> URLSessionConfiguration
  {
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 3
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = resourceTimeout
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return config
  }
  /// Проверяем адрес до добавления токена, чтобы токен получил только наш сервер.
  // Принимает только путь службы на защищённом адресе своего сервера и затем добавляет ключ
  // пользователя. Так неправильный путь не получит закрытые данные.
  private func request(_ path: String) throws -> URLRequest {
    guard path.hasPrefix("/v1/"),
      let url = URL(string: path, relativeTo: NetworkProfile.origin)?.absoluteURL,
      url.host == NetworkProfile.origin.host, url.scheme == "https"
    else { throw RepoError.invalidInput }
    var request = URLRequest(url: url)
    if let profile {
      request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
    }
    return request
  }
  /// Сохраняет код серверного ответа в ошибке, чтобы синхронизация могла отличить потерю доступа от
  /// временного сбоя.
  // Принимает ответ допустимого размера и сохраняет серверный признак ошибки. Для известного
  // отказа входа уведомляет владельца сеанса, чтобы временная ошибка и потеря доступа
  // обрабатывались по разным правилам.
  private func checked(_ data: Data, _ response: URLResponse) throws -> Data {
    guard data.count <= 2 * 1024 * 1024, let http = response as? HTTPURLResponse else {
      throw RepoError.io
    }
    guard (200..<300).contains(http.statusCode) else {
      let object = try? WireObject(data: data)
      let code = (object?.value["error"] as? [String: Any])?["code"] as? String ?? "http_error"
      if profile != nil, http.statusCode == 401,
        ["Войдите в аккаунт", "invalid_session", "account_deleted"].contains(code)
      {
        Task { @MainActor [weak self] in self?.onSessionRejected?(code) }
      }
      throw NetworkFailure(status: http.statusCode, code: code)
    }
    return data
  }
  // Повторяет одно чтение при потерянной связи или превышении времени и учитывает отмену.
  // Отправки с изменениями не проходят через этот повтор, чтобы не продублировать запись.
  private func read<T>(_ fetch: () async throws -> T) async throws -> T {
    do { return try await fetch() } catch let error as URLError
      where [.networkConnectionLost, .timedOut].contains(error.code)
    {
      try Task.checkCancellation()
      return try await fetch()
    }
  }

  // Готовит метод и данные запроса, повторяет чтение при временном отказе и проверяет ответ.
  // Остальные методы идут один раз, чтобы решение о повторе оставалось у вызывающего кода.
  func json(_ path: String, body: Data? = nil, method: String? = nil) async throws -> Data {
    var request = try request(path)
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let method { request.httpMethod = method }
    let reply: (Data, URLResponse)
    if request.httpMethod == "GET" {
      reply = try await read { try await session.data(for: request) }
    } else {
      reply = try await session.data(for: request)
    }
    let (data, response) = reply
    return try checked(data, response)
  }
  // Проверяет вид приглашения и передаёт его вместе с именем устройства. Возвращает профиль
  // доступа, который нужно сохранить для последующих запросов.
  func enroll(invitation: String, name: String) async throws -> NetworkProfile {
    guard invitation.count == 64, invitation.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      throw RepoError.invalidInput
    }
    let body = try JSONSerialization.data(withJSONObject: [
      "invitation": invitation, "deviceName": name,
    ])
    return try JSONDecoder().decode(
      NetworkProfile.self, from: await json("/v1/devices/enroll", body: body))
  }
  // Проверяет размер файла, считает контрольную сумму небольшими порциями и отправляет с номером
  // операции, чата или исходника. Для медленного исходника выбирает отдельное соединение, чтобы
  // обычные запросы не ждали.
  func upload(
    file: URL, mime: String, id: String, studioSource: Bool = false,
    chat: ChatID? = nil, parent: String? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> WireObject {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard (1...67_108_864).contains(size) else { throw RepoError.invalidInput }
    var digest = SHA256()
    let handle = try FileHandle(forReadingFrom: file)
    do {
      while let data = try handle.read(upToCount: 65536), !data.isEmpty {
        digest.update(data: data)
      }
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    var request = try request("/v1/uploads/" + id)
    request.httpMethod = "PUT"
    request.setValue(mime, forHTTPHeaderField: "Content-Type")
    request.setValue(String(size), forHTTPHeaderField: "Content-Length")
    request.setValue(hash, forHTTPHeaderField: "x-content-sha256")
    if let chat { request.setValue(String(chat), forHTTPHeaderField: "x-kandinsky-chat") }
    if let parent { request.setValue(parent, forHTTPHeaderField: "x-kandinsky-parent") }
    if studioSource {
      request.timeoutInterval = 3600
      request.setValue("1", forHTTPHeaderField: "x-kandinsky-source")
      request.setValue(profile?.deviceId, forHTTPHeaderField: "x-kandinsky-device")
    }
    let transport = studioSource ? sourceSession : session
    let (data, response) = try await transport.upload(
      for: request, fromFile: file,
      delegate: progress.map { StudioUploadProgress(size: Int64(size), progress: $0) })
    return try WireObject(data: checked(data, response))
  }
  // Использует уже сохранённый файл или скачивает во временное место. Сверяет длину и при наличии
  // контрольную сумму, затем перемещает файл на постоянный путь. Незавершённый файл по этому пути
  // не появится.
  func download(
    blob: String, to destination: URL, limit: Int64, progress: (@Sendable (Double) -> Void)? = nil
  ) async throws {
    guard [32, 64].contains(blob.count), blob.allSatisfy({ "0123456789abcdef".contains($0) }),
      (1...67_108_864).contains(limit)
    else { throw RepoError.invalidInput }
    if FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.setAttributes(
        [.modificationDate: Date()], ofItemAtPath: destination.path)
      return
    }
    let source = try request("/v1/media/" + blob)
    try Task.checkCancellation()
    progress?(0)
    let observer = progress.map(MediaDownloadProgress.init)
    defer { observer?.stop() }
    let (temporary, response) = try await read {
      try await session.download(for: source, delegate: observer)
    }
    observer?.stop()
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw RepoError.io
    }
    let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= limit,
      response.expectedContentLength < 0 || response.expectedContentLength == Int64(size)
    else { throw RepoError.corrupt }
    if blob.count == 64 {
      var digest = SHA256()
      let handle = try FileHandle(forReadingFrom: temporary)
      defer { try? handle.close() }
      while let data = try handle.read(upToCount: 65536), !data.isEmpty {
        digest.update(data: data)
      }
      guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == blob else {
        throw RepoError.corrupt
      }
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
    progress?(1)
  }
  // Проверяет номер файла и границы небольшого отрезка, просит точные байты и сверяет ответ.
  // Записывает сведения о чтении, чтобы отличить успешную передачу от отменённой.
  func range(blob: String, start: Int64, end: Int64, length: Int64, token: MediaCancellation) throws
    -> Data
  {
    guard [32, 64].contains(blob.count), blob.allSatisfy({ "0123456789abcdef".contains($0) }),
      start >= 0, end >= start, end < length, end - start < Int64(MediaRangeCache.chunkSize)
    else { throw RepoError.invalidInput }
    var value = try request("/v1/media/" + blob)
    value.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    do {
      let data = try rangeHTTP.read(
        value, expected: "bytes \(start)-\(end)/\(length)", count: Int(end - start + 1),
        token: token)
      rangeObserved?(blob, start, end, data.count, token.isCancelled)
      return data
    } catch {
      rangeObserved?(blob, start, end, 0, token.isCancelled)
      throw error
    }
  }
  /// Использует ту же сессию владельца, что и обычные запросы, чтобы команды и история относились к одной
  /// учётной записи.
  // Открывает постоянное соединение с ключом того же профиля и ограничивает размер входящего
  // пакета. Иначе команды могли бы попасть в чужой сеанс или занять память большим ответом.
  func socket() throws -> URLSessionWebSocketTask {
    let socket = session.webSocketTask(with: try request("/v1/ws"))
    socket.maximumMessageSize = 65536
    socket.resume()
    return socket
  }
  // Переводит текст или байты постоянного соединения в данные и сверяет предел. Неизвестный или
  // слишком большой пакет не попадает в разбор событий.
  func receive(_ socket: URLSessionWebSocketTask) async throws -> Data {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default: throw RepoError.corrupt
    }
    guard data.count <= 65536 else { throw RepoError.corrupt }
    return data
  }
  // Разбирает полученные байты в проверяемый набор полей ответа. Некорректные данные вызывают
  // ошибку до применения в базе.
  func object(_ data: Data) async throws -> WireObject { try WireObject(data: data) }
  /// Сохраняет устойчивый порядок полей, чтобы одинаковые данные не меняли запись только из-за порядка
  /// обхода словаря.
  // Записывает поля с постоянным порядком. При одинаковом содержимом порядок словаря не должен
  // менять байты пакета.
  func encode(_ value: [String: Any]) async throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
  /// Отдельное чтение участков видео тоже прекращается, чтобы закрытая учётная запись больше не
  /// продолжала старые запросы.
  // Отменяет обычные запросы, передачи исходников и чтение отрезков. После закрытия аккаунта
  // старое соединение не должно продолжать сетевую работу.
  func close() {
    rangeHTTP.close()
    session.invalidateAndCancel()
    sourceSession.invalidateAndCancel()
  }
}

extension NetworkAPI {
  // Выбирает запрос для регистрации или восстановления и передаёт адрес. У этих действий разные
  // правила и отдельные коды.
  func requestEmailCode(email: String, recovery: Bool) async throws {
    let path = recovery ? "/v1/demo/password-reset/request" : "/v1/demo/register/request"
    _ = try await json(path, body: JSONEncoder().encode(["email": email]))
  }

  // Отправляет почту, проверочный код и новый пароль на подтверждение смены. Ошибка сервера
  // передаётся экрану, чтобы он не показал успех раньше времени.
  func resetPassword(email: String, code: String, password: String) async throws {
    let body = try JSONEncoder().encode(["email": email, "code": code, "password": password])
    _ = try await json("/v1/demo/password-reset/confirm", body: body)
  }

  // Выбирает вход с паролем или завершение регистрации с кодом. Разбирает возвращённый профиль,
  // который используется для защищённых запросов.
  func signIn(email: String, password: String, registrationCode: String? = nil) async throws
    -> NetworkProfile
  {
    var fields = ["email": email, "password": password]
    fields["code"] = registrationCode
    let path = registrationCode == nil ? "/v1/demo/login" : "/v1/demo/register"
    let data = try await json(path, body: JSONEncoder().encode(fields))
    return try JSONDecoder().decode(NetworkProfile.self, from: data)
  }
}
