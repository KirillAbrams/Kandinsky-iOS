// Считает память готовых изображений и раздаёт удержания без повторного чтения. Старые кадры
// вытесняются, когда новые не помещаются.

import Foundation
import CoreGraphics
final class ImageByteBudget: @unchecked Sendable {
  private let lock = NSLock()
  private var used = 0, peak = 0, maximum = 48 * 1024 * 1024
  var limit: Int {
    // Читает предел байтов под блокировкой. Другой поток не меняет предел посередине чтения.
    get {
      lock.lock()
      defer { lock.unlock() }
      return maximum
    }
    // Задаёт неотрицательный предел памяти под блокировкой. Дальнейшие допуски используют новый
    // размер.
    set {
      lock.lock()
      maximum = max(0, newValue)
      lock.unlock()
    }
  }
  var bytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return used
  }
  var peakBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return peak
  }
  // Проверяет свободное место для положительного числа байтов без его занятия. Хранилище может
  // решить, нужно ли сначала убрать старые кадры.
  func canFit(_ value: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value > 0 && used <= maximum - value
  }
  // Проверяет свободный объём и сразу занимает его под той же блокировкой. Запоминает пик расхода
  // и возвращает право освободить байты.
  func reserve(_ value: Int) -> ImageByteCharge? {
    lock.lock()
    guard value > 0, used <= maximum - value else {
      lock.unlock()
      return nil
    }
    used += value
    peak = max(peak, used)
    lock.unlock()
    return ImageByteCharge(budget: self, bytes: value)
  }
  // Уменьшает текущую сумму и не даёт ей стать отрицательной. Место снова доступно для новых
  // изображений.
  fileprivate func release(_ value: Int) {
    lock.lock()
    used = max(0, used - value)
    lock.unlock()
  }
}
final class ImageByteCharge: @unchecked Sendable {
  private let lock = NSLock()
  private let budget: ImageByteBudget
  private var amount: Int
  // Запоминает полученный объём и общий подсчёт, куда его вернуть при закрытии. Один резерв
  // учитывается одним владельцем.
  init(budget: ImageByteBudget, bytes: Int) {
    self.budget = budget
    amount = bytes
  }
  // После чтения оставляет только реально занятый объём и возвращает разницу. Если фактический
  // размер больше обещанного, обработка не может тихо выйти за предел.
  func shrink(to actual: Int) throws {
    lock.lock()
    guard actual >= 0, actual <= amount else {
      lock.unlock()
      throw MediaError.unavailable
    }
    let difference = amount - actual
    amount = actual
    lock.unlock()
    budget.release(difference)
  }
  /// Сначала обнуляет собственную сумму, чтобы повторный вызов не освободил её второй раз.
  // Забирает остаток резерва и обнуляет его перед возвратом. Повторный вызов не освобождает те же
  // байты второй раз.
  func close() {
    lock.lock()
    let value = amount
    amount = 0
    lock.unlock()
    budget.release(value)
  }
  // Возвращает оставшийся резерв, если его не сняли явно. Счёт памяти не должен пережить закрытый
  // объект.
  deinit { close() }
}
final class ImagePixels: @unchecked Sendable {
  private let lock = NSLock()
  private var value: CGImage?
  private var references = 1, ownerClosed = false
  let byteSize: Int
  private let charge: ImageByteCharge
  let isTinyPreview: Bool
  // Запоминает рисунок, тип миниатюры и принадлежащий ему резерв. Размер берётся по строкам
  // пикселей, включая их заполнение.
  init(image: CGImage, charge: ImageByteCharge, isTinyPreview: Bool = false) {
    self.isTinyPreview = isTinyPreview
    value = image
    byteSize = image.bytesPerRow * image.height
    self.charge = charge
  }
  // Выдаёт отдельное удержание существующего рисунка. Несколько экранов могут показывать одни
  // байты и освобождать их независимо.
  func frame() -> PreparedImage? {
    lock.lock()
    guard value != nil, references > 0 else {
      lock.unlock()
      return nil
    }
    references += 1
    lock.unlock()
    return PreparedImage(pixels: self)
  }
  var image: CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  var hasOnlyCacheOwner: Bool {
    lock.lock()
    defer { lock.unlock() }
    return references == 1 && !ownerClosed
  }
  // Снимает исходное владение один раз. Если кадр ещё показан, его остальные удержания сохраняют
  // пиксели.
  func closeOwner() {
    lock.lock()
    guard !ownerClosed else {
      lock.unlock()
      return
    }
    ownerClosed = true
    releaseLocked()
  }
  // Снимает одно удержание под общей блокировкой. Картинка отдаётся только после выхода
  // последнего читателя.
  fileprivate func release() {
    lock.lock()
    releaseLocked()
  }
  // Уменьшает счётчик и снимает рисунок при нуле. Возвращает память уже вне блокировки, чтобы
  // освобождение не задерживало другие чтения.
  private func releaseLocked() {
    references -= 1
    let free = references == 0
    if free { value = nil }
    lock.unlock()
    if free { charge.close() }
  }
}
final class PreparedImage: MediaSurfacePayload, @unchecked Sendable {
  private let lock = NSLock()
  private var pixels: ImagePixels?
  private var closes = 0
  var closeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return closes
  }
  let orientation = 1
  var isTinyPreview: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pixels?.isTinyPreview == true
  }
  // Запоминает полученное удержание готовых пикселей. Его можно закрыть отдельно от общего
  // рисунка.
  fileprivate init(pixels: ImagePixels) { self.pixels = pixels }
  var image: CGImage? {
    lock.lock()
    defer { lock.unlock() }
    return pixels?.image
  }
  /// Позволяет передать готовый кадр другому экрану без повторного декодирования.
  // Даёт ещё одно удержание того же изображения, пока исходное открыто. Второй экран не
  // декодирует картинку заново.
  func retained() -> PreparedImage? {
    lock.lock()
    defer { lock.unlock() }
    return pixels?.frame()
  }
  // Забирает своё удержание и снимает ссылку под блокировкой, затем отдаёт её пикселям. Повторное
  // закрытие не освобождает чужой кадр.
  func close() {
    lock.lock()
    guard let p = pixels else {
      lock.unlock()
      return
    }
    pixels = nil
    closes += 1
    lock.unlock()
    p.release()
  }
  // Закрывает удержание, если владелец кадра уже исчез. Так забытая ссылка не держит бюджет.
  deinit { close() }
}
@MainActor final class ThumbnailCache {
  private var values: [String: ImagePixels] = [:], order: [String] = []
  private let budget: ImageByteBudget, entryLimit: Int, navigationBytes: Int
  // Задаёт общий бюджет, предел числа изображений и меньший объём для возврата в чат. Эти границы
  // действуют независимо.
  init(budget: ImageByteBudget, entryLimit: Int = 16, navigationBytes: Int = 8 * 1024 * 1024) {
    self.budget = budget
    self.entryLimit = entryLimit
    self.navigationBytes = navigationBytes
  }
  // Берёт кадр по ключу и переносит запись в конец порядка использования. Прочитанное недавно не
  // должно вытесняться первым.
  func frame(_ key: String) -> PreparedImage? {
    guard let value = values[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return value.frame()
  }
  // Удаляет старые кадры, которые больше никто не держит, пока не поместится новый. При занятости
  // всех кадров возвращает отказ вместо превышения.
  func makeRoom(_ amount: Int) -> Bool {
    while !budget.canFit(amount),
      let index = order.firstIndex(where: { values[$0]?.hasOnlyCacheOwner == true })
    {
      let key = order.remove(at: index)
      values.removeValue(forKey: key)?.closeOwner()
    }
    return budget.canFit(amount)
  }
  /// Старые кадры вытесняются при достижении предела памяти или числа записей.
  // Заменяет прежний рисунок по тому же ключу и убирает ранние записи по числу и сумме байтов.
  // Отдельные экранные удержания при вытеснении ещё живут.
  func insert(_ value: ImagePixels, key: String, maximumBytes: Int = .max) {
    if let old = values.removeValue(forKey: key) {
      old.closeOwner()
      order.removeAll { $0 == key }
    }
    values[key] = value
    order.append(key)
    var bytes = values.values.reduce(0) { $0 + $1.byteSize }
    while values.count > entryLimit || bytes > max(0, maximumBytes) {
      guard let oldest = order.first else { break }
      bytes -= values[oldest]?.byteSize ?? 0
      evictFirst()
    }
  }
  // Убирает самое раннее по использованию изображение и снимает владение хранилища. Если его
  // больше никто не показывает, байты освобождаются.
  private func evictFirst() {
    guard !order.isEmpty else { return }
    let key = order.removeFirst()
    values.removeValue(forKey: key)?.closeOwner()
  }
  // Убирает полные изображения и оставляет небольшое число байтов для возврата. Соседний экран
  // получает полезные готовые кадры без удержания крупных оригиналов.
  func retainNavigationImages() {
    for key in order.filter({ $0.contains("@original:") }) {
      values.removeValue(forKey: key)?.closeOwner()
      order.removeAll { $0 == key }
    }
    var bytes = values.values.reduce(0) { $0 + $1.byteSize }
    while bytes > navigationBytes, let key = order.first {
      bytes -= values[key]?.byteSize ?? 0
      evictFirst()
    }
  }
  // Возвращает владение всеми картинками и очищает порядок. Чтобы счёт памяти обнулился, экраны
  // также должны закрыть свои кадры.
  func clear() {
    for value in values.values { value.closeOwner() }
    values.removeAll()
    order.removeAll()
  }
}
