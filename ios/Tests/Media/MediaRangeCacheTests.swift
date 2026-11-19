// Проверяет чтение частей видео, повторное открытие и сборку целого файла на временном диске.
// Сверяет байты с известным исходником.

import XCTest
import CryptoKit
import Network
@testable import Kandinsky
final class MediaRangeCacheTests: XCTestCase {
  // Читает конец файла, закрывает источник и снова читает тот же конец без сети. Затем получает
  // остальные части и сравнивает готовый файл. Закрытый источник не должен принять новое чтение.
  func testSeekDiskReuseAndVerifiedPromotion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data((0..<MediaRangeCache.chunkSize * 3 + 17).map { UInt8($0 % 251) }),
      blob = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      original = root.appendingPathComponent("media/remote/" + blob + ".mp4")
    var calls = 0
    let first = try MediaRangeCache(
      root: root, blob: blob, length: Int64(bytes.count), original: original
    ) { start, end, _ in
      calls += 1
      return bytes.subdata(in: Int(start)..<Int(end + 1))
    }
    let tail = try first.read(
      offset: Int64(bytes.count - 10), count: 10, cancellation: MediaCancellation())
    XCTAssertEqual(tail, bytes.suffix(10))
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    first.close()
    let resumed = try MediaRangeCache(
      root: root, blob: blob, length: Int64(bytes.count), original: original
    ) { start, end, _ in
      calls += 1
      return bytes.subdata(in: Int(start)..<Int(end + 1))
    }
    XCTAssertEqual(
      try resumed.read(
        offset: Int64(bytes.count - 10), count: 10, cancellation: MediaCancellation()), tail)
    XCTAssertEqual(calls, 1, "A reopened partial must work from disk")
    for chunk in 0..<3 {
      _ = try resumed.read(
        offset: Int64(chunk * MediaRangeCache.chunkSize), count: 1,
        cancellation: MediaCancellation())
    }
    XCTAssertEqual(calls, 4)
    XCTAssertEqual(try Data(contentsOf: original), bytes)
    resumed.close()
    XCTAssertThrowsError(try resumed.read(offset: 0, count: 1, cancellation: MediaCancellation()))
  }
  // Возвращает слишком короткую часть и ждёт отказа. Файл части не должен появиться, иначе
  // следующее открытие могло бы принять обрыв за готовые данные.
  func testShortRangeIsNotCommitted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MediaRangeCache(
      root: root, blob: String(repeating: "a", count: 64), length: 1024,
      original: root.appendingPathComponent("original")
    ) { _, _, _ in Data(repeating: 1, count: 10) }
    XCTAssertThrowsError(try cache.read(offset: 0, count: 1, cancellation: MediaCancellation()))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          "media/ranges/" + String(repeating: "a", count: 64) + "/0.chunk"
        ).path))
    cache.close()
  }

  func testRangeTransportAcceptsOnlyTheRequestedPartialResponse() async throws {
    let range = "bytes 3-6/10"
    let expected = Data("3456".utf8)
    let listener = try await listenForRangeRequests { request in
      XCTAssertTrue(request.lowercased().contains("\r\nrange: bytes=3-6\r\n"))
      let lines = request.components(separatedBy: "\r\n")
      let route = lines.first?.split(separator: " ").dropFirst().first
      switch route {
      case "/valid":
        return Self.rangeResponse(range: range, length: 4, body: "3456")
      case "/wrong-range":
        return Self.rangeResponse(range: "bytes 0-3/10", length: 4, body: "0123")
      case "/wrong-size":
        return Self.rangeResponse(range: range, length: 6, body: "345678")
      case "/excess":
        return Self.rangeResponse(range: range, body: "345678")
      case "/short":
        return Self.rangeResponse(range: range, body: "34")
      case "/whole-file":
        return "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n0123456789"
      case "/redirect":
        return "HTTP/1.1 302 Found\r\nLocation: /valid\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      default:
        XCTFail("Неожиданный запрос: \(request)")
        return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      }
    }
    defer { listener.cancel() }
    let port = try XCTUnwrap(listener.port?.rawValue)
    let transport = MediaRangeHTTP()
    defer { transport.close() }

    func load(_ route: String, token: MediaCancellation = MediaCancellation()) async throws -> Data {
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)"))
      var request = URLRequest(url: url)
      request.setValue("bytes=3-6", forHTTPHeaderField: "Range")
      let outgoing = request
      return try await Task.detached {
        try transport.read(outgoing, expected: range, count: expected.count, token: token)
      }.value
    }

    let first = try await load("valid")
    XCTAssertEqual(first, expected)
    for route in ["wrong-range", "wrong-size", "excess", "short"] {
      do {
        _ = try await load(route)
        XCTFail("Клиент принял неполный или неверный ответ для \(route)")
      } catch {
        XCTAssertEqual(error as? MediaError, .corrupt, route)
      }
    }
    for (route, status) in [("whole-file", 200), ("redirect", 302)] {
      do {
        _ = try await load(route)
        XCTFail("Клиент принял ответ без частичного содержимого для \(route)")
      } catch {
        XCTAssertEqual((error as? NetworkFailure)?.status, status)
        XCTAssertEqual((error as? NetworkFailure)?.code, "media_range")
      }
    }
    let cancelled = MediaCancellation()
    cancelled.cancel()
    do {
      _ = try await load("not-requested", token: cancelled)
      XCTFail("Отменённый запрос вернул данные")
    } catch {
      XCTAssertEqual(error as? MediaError, .cancelled)
    }
    let next = try await load("valid")
    XCTAssertEqual(next, expected, "Отклонённые ответы не должны ломать следующее чтение")
  }

  func testCancellingAStartedRangeReadDoesNotWaitForTheServerBody() async throws {
    let requested = expectation(description: "Локальный сервер принял запрос")
    let returned = expectation(description: "Чтение завершилось до ответа сервера")
    let release = DispatchSemaphore(value: 0)
    let listener = try await listenForRangeRequests { _ in
      requested.fulfill()
      _ = release.wait(timeout: .now() + 5)
      return Self.rangeResponse(range: "bytes 0-3/4", length: 4, body: "read")
    }
    defer {
      release.signal()
      listener.cancel()
    }
    let port = try XCTUnwrap(listener.port?.rawValue)
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/slow"))
    let transport = MediaRangeHTTP()
    defer { transport.close() }
    let token = MediaCancellation()
    let request = URLRequest(url: url)
    let read = Task.detached {
      defer { returned.fulfill() }
      return try transport.read(request, expected: "bytes 0-3/4", count: 4, token: token)
    }

    await fulfillment(of: [requested], timeout: 3)
    token.cancel()
    await fulfillment(of: [returned], timeout: 3)
    do {
      _ = try await read.value
      XCTFail("Отменённый запрос вернул файл")
    } catch {
      XCTAssertEqual(error as? MediaError, .cancelled)
    }
  }

  private static func rangeResponse(range: String, length: Int? = nil, body: String) -> String {
    let size = length.map { "Content-Length: \($0)\r\n" } ?? ""
    return "HTTP/1.1 206 Partial Content\r\nContent-Range: \(range)\r\n" +
      size + "Connection: close\r\n\r\n" + body
  }

  private func listenForRangeRequests(
    reply: @escaping @Sendable (String) -> String
  ) async throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = expectation(description: "Локальный источник ответов готов")
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.fulfill()
      case .failed(let error):
        XCTFail("Не удалось открыть локальный источник: \(error)")
        ready.fulfill()
      default:
        break
      }
    }
    let queue = DispatchQueue(label: "Проверка чтения диапазона")
    listener.newConnectionHandler = { connection in
      connection.start(queue: queue)
      Self.receiveRangeRequest(connection, reply: reply)
    }
    listener.start(queue: queue)
    await fulfillment(of: [ready], timeout: 3)
    if listener.port == nil {
      listener.cancel()
      throw URLError(.cannotConnectToHost)
    }
    return listener
  }

  private static func receiveRangeRequest(
    _ connection: NWConnection, header: Data = Data(),
    reply: @escaping @Sendable (String) -> String
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _, done, error in
      var buffer = header
      if let bytes { buffer.append(bytes) }
      if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
        let response = Data(reply(request).utf8)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
      } else if !done && error == nil && buffer.count < 4096 {
        receiveRangeRequest(connection, header: buffer, reply: reply)
      } else {
        connection.cancel()
      }
    }
  }
}
