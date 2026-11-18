// Открытие истории ждёт, пока подготовлены видимые строки и сцена может их показать. Для фото и
// видео ждём лишь ограниченное время, иначе один недоступный файл задержал бы весь экран.

import UIKit

extension ChatScrollHost {
  // Завершаем прежнее ожидание, сохраняем новый вызов и ставим срок подготовки медиа. Готовый
  // кадр или истечение срока запускают повторную проверку.
  func prepareInitialFrame() async throws {
    guard !closed else { throw RepoError.cancelled }
    finishInitialFrame(.failure(RepoError.cancelled))
    try await withCheckedThrowingContinuation { continuation in
      initialFrame = continuation
      initialMediaDeadline = CACurrentMediaTime() + 0.25
      scene.onStaticReady = { [weak self] in self?.schedule() }
      let timeout = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.schedule() }
      }
      initialTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: timeout)
      schedule()
    }
  }

  // Забираем ожидающий вызов, снимаем срок и отписываемся от готовности сцены. Результат отдаём
  // один раз, даже если следом придёт ещё один сигнал.
  func finishInitialFrame(_ result: Result<Void, Error>) {
    let continuation = initialFrame
    initialFrame = nil
    initialTimeout?.cancel()
    initialTimeout = nil
    scene.onStaticReady = nil
    continuation?.resume(with: result)
  }

  // Проверяем, что есть подготовленные ресурсы для видимых строк и сцена содержит их фрагменты.
  // Для изображений ждём до срока, а текст и раскладка остаются обязательными.
  func publishInitialFrame(_ fragments: [SceneFragment]) {
    guard initialFrame != nil, initialIndexReady else { return }
    let visible = index.visible(
      offset: max(0, Double(viewportOffsetY + overlayTop)),
      height: Double(max(0, bounds.height - overlayTop - overlayBottom)), overscan: 0
    ).map { index.rows[$0] }
    guard
      visible.allSatisfy({ meta in loaded[meta.messageID].flatMap { cache.value(key($0)) } != nil })
    else { return }
    let view = scene.viewport ?? .zero,
      ids = Set(fragments.filter { $0.frame.intersects(view) }.map(\.id))
    guard visible.isEmpty || !ids.isEmpty else { return }
    if scene.presentationReady(ids, requireMedia: CACurrentMediaTime() < initialMediaDeadline) {
      finishInitialFrame(.success(()))
    }
  }
}
