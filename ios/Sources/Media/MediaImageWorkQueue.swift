// Разводит поиск местного файла, скачивание и чтение пикселей по разным очередям. Долгая сеть не
// занимает работника, который нужен готовому файлу.

import Foundation

/// Поиск на диске и ожидание сети не занимают исполнителя, который готовит пиксели.
@MainActor final class MediaImageWorkQueue {
  typealias Source = (URL, String)
  private let lookup = MediaDecodeQueue()
  private let downloads = MediaDecodeQueue()
  private let decoding = MediaDecodeQueue(maximumWorkers: 1)
  private var requests: [UUID: MediaCancellation] = [:]
  private var closed = false

  // Ставит поиск местной копии, при необходимости запускает отдельно скачивание и только потом
  // чтение пикселей. Сигнал отмены доходит до каждого начатого шага.
  func submit(
    priority: Int, fetch: MediaCancellation,
    local: @escaping (MediaCancellation) throws -> Source?,
    remote: @escaping (MediaCancellation) throws -> Source,
    admit: @escaping () throws -> ImageByteCharge,
    decode: @escaping (Source, ImageByteCharge) throws -> ImagePixels,
    willDownload: @escaping () -> Bool = { true },
    completion: @escaping (Result<ImagePixels, Error>) -> Void
  ) -> MediaCancellation {
    let identity = UUID(), request = MediaCancellation()
    requests[identity] = request
    // Убирает запрос из списка и прекращает поиск файла, затем отдаёт результат действующему
    // получателю. Если получатель ушёл, освобождает изображение сам.
    func finish(_ result: Result<ImagePixels, Error>) {
      requests.removeValue(forKey: identity)
      fetch.cancel()
      if !closed && request.finish() {
        completion(result)
      } else {
        if case let .success(pixels) = result { pixels.closeOwner() }
        completion(.failure(MediaError.cancelled))
      }
    }
    // Перед чтением пикселей снова резервирует место и проверяет отмену. При ошибке снимает
    // резерв, иначе последующая загрузка считала бы освободившуюся память занятой.
    func prepare(_ source: Source) {
      guard !closed, !request.isCancelled else {
        finish(.failure(MediaError.cancelled))
        return
      }
      let work = decoding.submit(
        priority: priority,
        work: {
          if fetch.isCancelled { throw MediaError.cancelled }
          // Кэш мог заполниться за время загрузки. Освобождаем место перед чтением пикселей.
          let charge = try DispatchQueue.main.sync { try admit() }
          do {
            if fetch.isCancelled { throw MediaError.cancelled }
            return try decode(source, charge)
          } catch {
            charge.close()
            throw error
          }
        }, dispose: { $0.closeOwner() }, completion: { finish($0) })
      request.onCancel { fetch.cancel(); work.cancel() }
    }
    let work = lookup.submit(
      priority: priority, work: { try local(fetch) }, dispose: { _ in },
      completion: { result in
        guard !self.closed, !request.isCancelled else {
          finish(.failure(MediaError.cancelled))
          return
        }
        switch result {
        case let .success(source?): prepare(source)
        case .success(nil):
          guard willDownload() else {
            finish(.failure(MediaError.cancelled))
            return
          }
          let download = self.downloads.submit(
            priority: priority, work: { try remote(fetch) }, dispose: { _ in },
            completion: { result in
              switch result {
              case let .success(source): prepare(source)
              case let .failure(error): finish(.failure(error))
              }
            })
          request.onCancel { fetch.cancel(); download.cancel() }
        case let .failure(error): finish(.failure(error))
        }
      })
    request.onCancel { fetch.cancel(); work.cancel() }
    return request
  }

  // Отменяет текущие запросы и закрывает все три очереди. Запоздалые изображения не должны
  // вернуться к закрытому владельцу.
  func close() {
    guard !closed else { return }
    closed = true
    let active = Array(requests.values)
    requests.removeAll()
    active.forEach { $0.cancel() }
    lookup.close()
    downloads.close()
    decoding.close()
  }
}
