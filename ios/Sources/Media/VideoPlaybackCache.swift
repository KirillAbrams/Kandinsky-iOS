// Хранит место просмотра и остановленные кадры видео. Использует общий предел памяти с
// фотографиями и читает сохранённые кадры с диска в фоне.

import CoreGraphics
import Foundation

@MainActor final class VideoPlaybackCache {
  private let budget: ImageByteBudget
  private let frames: ThumbnailCache
  private let disk: VideoCoverDiskCache?
  private let writer = MediaDecodeQueue(maximumWorkers: 1, maximumPending: 1)
  private let reader = MediaDecodeQueue(maximumWorkers: 1)
  private let captureQueue = MediaDecodeQueue(maximumWorkers: 1, maximumPending: 1)
  private let restores = MediaThumbnailRequests()
  private var preparations: [VideoPlaybackKey: MediaCancellation?] = [:]
  private var captures: [VideoPlaybackKey: (work: CoverCapture, token: MediaCancellation)] = [:]
  private var writes: [CoverWrite] = []
  private final class CoverCapture: @unchecked Sendable {
    struct Input {
      let sourceCharge: ImageByteCharge
      let frameCharge: ImageByteCharge
      let render: (Int, Int) -> CGImage?
    }
    private let lock = NSLock()
    private var input: Input?

    // Удерживает исходные пиксели, место для результата и действие подготовки. Ожидающая задача
    // не может потерять память, которую ей уже выделили.
    init(sourceCharge: ImageByteCharge, frameCharge: ImageByteCharge,
      render: @escaping (Int, Int) -> CGImage?
    ) {
      input = Input(sourceCharge: sourceCharge, frameCharge: frameCharge, render: render)
    }
    // Забирает подготовку под блокировкой только один раз. После этого работа сама владеет
    // резервом, пока рисует кадр.
    func take() -> Input? {
      lock.lock()
      defer { lock.unlock() }
      let work = input
      input = nil
      return work
    }
    // Снимает ожидающую подготовку и отменяет задачу. Если она уже началась, её резерв остаётся
    // до завершения чтения.
    func cancel(_ token: MediaCancellation) {
      // Начатая обработка удерживает свои пиксели до конца работы.
      _ = take()
      token.cancel()
    }
  }
  private final class CoverWrite: @unchecked Sendable {
    private let gate = NSLock()
    private var frame: PreparedImage?
    private var charge: ImageByteCharge?
    // Удерживает готовый кадр и дополнительную память записи. Очередь может сохранить файл позже,
    // даже если экран уже ушёл.
    init(frame: PreparedImage, charge: ImageByteCharge) {
      self.frame = frame
      self.charge = charge
    }
    // Записывает ещё доступный кадр по сохранённому номеру отзыва. После попытки возвращает оба
    // удержания, в том числе при ошибке диска.
    func perform(disk: VideoCoverDiskCache, key: VideoPlaybackKey, epoch: UInt64) throws {
      gate.lock()
      defer {
        release()
        gate.unlock()
      }
      if let image = frame?.image { try disk.store(image, key: key, epoch: epoch) }
    }
    // Снимает удержания записи под блокировкой. Закрытие не должно освободить кадр, пока та же
    // запись держит его внутри.
    func close() {
      gate.lock()
      release()
      gate.unlock()
    }
    // Закрывает кадр и резерв временных байтов и убирает ссылки. Повторное освобождение больше
    // ничего не удерживает.
    private func release() {
      frame?.close()
      frame = nil
      charge?.close()
      charge = nil
    }
  }
  private var positions: [VideoPlaybackKey: Double] = [:]
  private var recent: [VideoPlaybackKey] = []
  private(set) var generation = 0
  private var closed = false

  // Создаёт ограниченное хранилище кадров и добавляет дисковую копию при наличии папки. Оба
  // раздела используют общий счёт памяти.
  init(budget: ImageByteBudget, root: URL? = nil) {
    disk = root.map(VideoCoverDiskCache.init)
    self.budget = budget
    frames = ThumbnailCache(budget: budget, entryLimit: 64)
  }
  // Читает последнее сохранённое время для выбранного вложения. Если ролик ещё не смотрели, начинает
  // с нуля.
  func position(_ key: VideoPlaybackKey) -> Double { positions[key] ?? 0 }
  // Пропускает старые сеансы и недопустимое время, затем запоминает место и оставляет до двухсот
  // пятидесяти шести записей. Запоздалый игрок не перезаписывает позицию.
  func rememberPosition(_ value: Double, key: VideoPlaybackKey, generation: Int) {
    guard !closed, self.generation == generation, value.isFinite, value >= 0 else { return }
    positions[key] = value
    recent.removeAll { $0 == key }
    recent.append(key)
    while recent.count > 256 { positions.removeValue(forKey: recent.removeFirst()) }
  }
  // Возвращает удержание готового кадра из памяти. Показу не приходится ждать дисковое чтение.
  func frame(_ key: VideoPlaybackKey) -> PreparedImage? { frames.frame(key.cacheKey) }
  // Ищет готовый кадр, только если хранилище ещё открыто. Закрытая лента уже не выдаёт
  // изображение.
  func cover(_ key: VideoPlaybackKey) -> PreparedImage? {
    guard !closed else { return nil }
    return frame(key)
  }
  // Делит дисковое чтение между запросами и сверяет номер попытки и отзыва перед выдачей. Если за
  // время чтения появился новый кадр, отдаёт его вместо старого файла.
  func restoreCover(
    _ key: VideoPlaybackKey, priority: Int = 1,
    completion: @escaping (Result<PreparedImage, Error>) -> Void
  ) -> MediaCancellation {
    let ticket = generation
    let epoch = disk?.epoch()
    return restores.submit(
      key: key.cacheKey, priority: priority, progress: { _ in },
      start: { priority, _, _, done in
        if let cached = self.cover(key) {
          let token = MediaCancellation()
          token.onCancel { cached.close() }
          DispatchQueue.main.async {
            if !self.closed, self.generation == ticket, self.disk?.epoch() == epoch, token.finish()
            {
              done(.success(cached))
            } else {
              cached.close()
              done(.failure(MediaError.cancelled))
            }
          }
          return token
        }
        let disk = self.disk
        let budget = self.budget
        return self.reader.submit(
          priority: priority,
          work: { disk?.readPixels(key, budget: budget) },
          dispose: { $0?.closeOwner() },
          completion: { result in
            MainActor.assumeIsolated {
              let pixels = try? result.get()
              if self.closed || self.generation != ticket || self.disk?.epoch() != epoch {
                pixels?.closeOwner()
                done(.failure(MediaError.cancelled))
              } else if let pixels {
                if let fresh = self.frames.frame(key.cacheKey) {
                  pixels.closeOwner()
                  done(.success(fresh))
                } else {
                  self.retainFrame(pixels, key: key)
                  if let frame = self.frames.frame(key.cacheKey) {
                    done(.success(frame))
                  } else {
                    done(.failure(MediaError.unavailable))
                  }
                }
              } else {
                if case .failure(let error) = result {
                  done(.failure(error))
                } else {
                  done(.failure(MediaError.unavailable))
                }
              }
            }
          })
      },
      completion: { result in
        MainActor.assumeIsolated {
          guard !self.closed, self.generation == ticket, self.disk?.epoch() == epoch else {
            if case .success(let frame) = result { frame.close() }
            completion(.failure(MediaError.cancelled))
            return
          }
          completion(result)
        }
      })
  }
  // Оставляет до четырёх ближайших ключей и отменяет подготовку остальных. Готовые кадры не
  // дублирует, а прочитанное сразу оставляет в общем хранилище.
  func prepareCovers(_ keys: [VideoPlaybackKey]) {
    guard !closed else { return }
    var wanted: [VideoPlaybackKey] = []
    for key in keys where !wanted.contains(key) {
      wanted.append(key)
      if wanted.count == 4 { break }
    }
    for key in Array(preparations.keys) where !wanted.contains(key) {
      if let pending = preparations.removeValue(forKey: key) { pending?.cancel() }
    }
    for key in wanted where !preparations.keys.contains(key) {
      preparations.updateValue(nil, forKey: key)
      if let cached = cover(key) {
        cached.close()
      } else {
        preparations[key] = restoreCover(key, priority: 0) { result in
          if case .success(let frame) = result { frame.close() }
          if self.preparations.keys.contains(key) {
            self.preparations.updateValue(nil, forKey: key)
          }
        }
      }
    }
  }
  // Просит убрать старые кадры без активного читателя до подготовки пикселей. Если места всё ещё
  // мало, создание получит отказ.
  func makeRoom(_ amount: Int) -> Bool { frames.makeRoom(amount) }

  // Проверяет сеанс, резервирует место и сохраняет готовый кадр сразу. Более ранняя ожидающая
  // копия отменяется, чтобы позже не заменить этот кадр.
  func rememberFrame(
    key: VideoPlaybackKey, generation: Int, width: Int, height: Int,
    render: (Int, Int) -> CGImage?
  ) {
    guard !closed, self.generation == generation,
      let (w, h, charge) = reserveFrame(width: width, height: height),
      let pixels = Self.renderFrame(width: w, height: h, charge: charge, render: render)
    else { return }
    if let queued = captures.removeValue(forKey: key) { queued.work.cancel(queued.token) }
    publishCapture(pixels, key: key, epoch: disk?.epoch() ?? 0)
  }

  // Резервирует память исходника и будущего кадра до начала фонового рисования. Пропускает
  // дубликаты и проверяет отзыв перед выдачей, иначе запоздалый рисунок вернулся бы на экран.
  func enqueueFrame(
    key: VideoPlaybackKey, generation: Int, width: Int, height: Int, sourceBytes: Int,
    published: (() -> Void)? = nil, render: @escaping (Int, Int) -> CGImage?
  ) {
    guard !closed, self.generation == generation, captures[key] == nil, captures.count < 2,
      let sourceCharge = budget.reserve(sourceBytes),
      let (w, h, charge) = reserveFrame(width: width, height: height)
    else { return }
    let capture = CoverCapture(sourceCharge: sourceCharge, frameCharge: charge, render: render)
    let epoch = disk?.epoch()
    let token = captureQueue.submit(work: { () -> ImagePixels? in
      guard let input = capture.take() else { return nil }
      return withExtendedLifetime(input.sourceCharge) {
        Self.renderFrame(width: w, height: h, charge: input.frameCharge, render: input.render)
      }
    }, dispose: { $0?.closeOwner() }, completion: { [weak self] result in
      MainActor.assumeIsolated {
        let pixels = (try? result.get()) ?? nil
        guard let self, self.captures[key]?.work === capture else { pixels?.closeOwner(); return }
        self.captures.removeValue(forKey: key)
        guard let pixels else { return }
        guard !self.closed, self.generation == generation, self.disk?.epoch() == epoch else {
          pixels.closeOwner()
          return
        }
        self.publishCapture(pixels, key: key, epoch: epoch ?? 0)
        published?()
      }
    })
    captures[key] = (capture, token)
  }

  // Уменьшает крупный кадр до допустимой стороны и учитывает шаг строк и запас работы. Выделяет
  // байты до создания, чтобы копия не вышла за общий предел.
  private func reserveFrame(width: Int, height: Int) -> (Int, Int, ImageByteCharge)? {
    guard width > 0, height > 0 else { return nil }
    let scale = min(1, 1024.0 / Double(max(width, height)))
    let w = max(1, Int(Double(width) * scale))
    let h = max(1, Int(Double(height) * scale))
    let amount = ((w * 4 + 255) / 256 * 256) * h + 4096
    guard frames.makeRoom(amount), let charge = budget.reserve(amount) else { return nil }
    return (w, h, charge)
  }

  // Рисует кадр и сокращает резерв до фактического размера. При отказе рисования или превышении
  // сразу возвращает память.
  private nonisolated static func renderFrame(
    width w: Int, height h: Int, charge: ImageByteCharge, render: (Int, Int) -> CGImage?
  ) -> ImagePixels? {
    guard let image = render(w, h) else {
      charge.close()
      return nil
    }
    do { try charge.shrink(to: image.bytesPerRow * image.height) } catch {
      charge.close()
      return nil
    }
    return ImagePixels(image: image, charge: charge)
  }

  // Помещает готовый кадр в память и при возможности назначает запись на диск. Ближайший показ
  // получает результат без ожидания записи.
  private func publishCapture(_ pixels: ImagePixels, key: VideoPlaybackKey, epoch: UInt64) {
    retainFrame(pixels, key: key)
    persist(key, bytes: pixels.byteSize, epoch: epoch)
  }
  // Сохраняет кадр под ключом и ограничивает место меньшим из отдельного предела и доли общей
  // памяти. Кадры видео не вытесняют все фотографии.
  private func retainFrame(_ pixels: ImagePixels, key: VideoPlaybackKey) {
    let maximumBytes = min(16 * 1024 * 1024, budget.limit / 3)
    frames.insert(pixels, key: key.cacheKey, maximumBytes: maximumBytes)
  }
  // Удерживает не более двух ожидающих записей и учитывает их временную память. Если места нет,
  // оставляет только копию в памяти.
  private func persist(_ key: VideoPlaybackKey, bytes: Int, epoch: UInt64) {
    guard let disk else { return }
    guard writes.count < 2, let frame = frames.frame(key.cacheKey) else { return }
    guard let charge = budget.reserve(bytes * 2) else {
      frame.close()
      return
    }
    let write = CoverWrite(frame: frame, charge: charge)
    writes.append(write)
    writer.submit(
      work: { try write.perform(disk: disk, key: key, epoch: epoch) }, dispose: { _ in },
      completion: { [weak self] _ in
        MainActor.assumeIsolated {
          write.close()
          self?.writes.removeAll { $0 === write }
        }
      })
  }
  // Меняет номер состояния, отменяет снимки и чтения и убирает изображения. Места просмотра
  // сохраняются, чтобы можно было вернуться к ролику.
  func clearFrames() {
    generation += 1
    let activeCaptures = captures.values
    captures.removeAll()
    activeCaptures.forEach { $0.work.cancel($0.token) }
    let pending = Array(preparations.values)
    preparations.removeAll()
    pending.forEach { $0?.cancel() }
    restores.clear()
    frames.clear()
  }
  // Закрывает очереди и диск, освобождает записи и забывает позиции. Ушедший владелец больше не
  // может выдать старый кадр.
  func close() {
    closed = true
    captureQueue.close()
    reader.close()
    writer.close()
    writes.forEach { $0.close() }
    writes.removeAll()
    disk?.close()
    clearFrames()
    positions.removeAll()
    recent.removeAll()
  }
}
