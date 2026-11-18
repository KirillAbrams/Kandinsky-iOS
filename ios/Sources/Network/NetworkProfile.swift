// Хранит выбранный вход, список запомненных аккаунтов и последнее место в списке чатов. Отметки
// об удалении позволяют дочистить данные владельца после перезапуска.

import Foundation
import Security

struct NetworkProfile: Codable, Sendable, CustomStringConvertible {
  static let origin: URL = {
    let configured = Bundle.main.object(forInfoDictionaryKey: "KandinskyBridgeOrigin") as? String
    if let configured, let value = URL(string: configured), value.scheme == "https",
      value.host != nil, value.user == nil, value.query == nil, value.fragment == nil
    {
      return value
    }
    return URL(string: "https://206.223.248.85:8449")!
  }()
  let userId: Int64
  let deviceId: String
  let name: String
  let token: String
  let expiresAtMs: Int64
  var username: String? = nil
  var description: String { "NetworkProfile(userId: \(userId), credentials: redacted)" }
}

struct NetworkCredentialFailure: Error { let status: OSStatus }

final class NetworkCredentialStore: @unchecked Sendable {
  private let service: String
  private let gate = NSLock()
  // Запоминает имя раздела системного хранилища ключей. Оно отделяет эти записи входа от других
  // записей приложения.
  init(service: String) { self.service = service }
  // Собирает условия поиска по разделу и имени записи. Тот же набор используют чтение, запись и
  // удаление, чтобы они обращались к одному месту.
  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
  // Читает одну запись из системного хранилища, различает отсутствие и ошибку системы и проверяет
  // размер. Иначе повреждённые данные могли бы попасть в разбор профиля.
  private func read(_ account: String) throws -> Data? {
    var value = query(account)
    value[kSecReturnData as String] = true
    value[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(value as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw NetworkCredentialFailure(status: status) }
    guard let data = result as? Data, data.count <= 65536 else { throw RepoError.corrupt }
    return data
  }
  // Перезаписывает запись или создаёт её с доступом после первой разблокировки этого телефона.
  // Такая запись не переносит ключ входа на другой телефон.
  private func write(_ data: Data, account: String) throws {
    let key = query(account)
    let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var value = key
      value[kSecValueData as String] = data
      value[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(value as CFDictionary, nil)
      guard added == errSecSuccess else { throw NetworkCredentialFailure(status: added) }
    } else if status != errSecSuccess {
      throw NetworkCredentialFailure(status: status)
    }
  }
  // Проверяет номер владельца, длину обозначения устройства и вид ключа входа. Без проверки
  // повреждённая запись выглядела бы как пригодный вход.
  private func checked(_ profile: NetworkProfile) throws -> NetworkProfile {
    guard profile.userId > 0, profile.deviceId.count <= 64, profile.token.count == 64,
      profile.token.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw RepoError.corrupt }
    return profile
  }
  // Восстанавливает текущий профиль из отдельной системной записи. Перед выдачей сверяет его
  // поля, чтобы приложение не использовало повреждённый ключ.
  private func current() throws -> NetworkProfile? {
    try read("device").map { try checked(JSONDecoder().decode(NetworkProfile.self, from: $0)) }
  }
  // Читает сохранённый список, ограничивает его восемью профилями и проверяет каждый. Если запись
  // пуста, отдаёт пустой список.
  private func remembered() throws -> [NetworkProfile] {
    let values =
      try read("accounts").map { try JSONDecoder().decode([NetworkProfile].self, from: $0) } ?? []
    guard values.count <= 8 else { throw RepoError.corrupt }
    return try values.map(checked)
  }
  // Читает активный вход под блокировкой, чтобы он не сменился посередине чтения.
  func load() throws -> NetworkProfile? {
    gate.lock()
    defer { gate.unlock() }
    return try current()
  }
  // Ставит активный профиль первым и исключает его повтор в списке. Выполняет чтение вместе,
  // чтобы переключение пользователя не перемешало два входа.
  func profiles() throws -> [NetworkProfile] {
    gate.lock()
    defer { gate.unlock() }
    let values = try remembered()
    guard let current = try current() else { return values }
    return [current] + values.filter { $0.userId != current.userId }
  }
  // Проверяет новый профиль, поднимает его в начало списка, сохраняет предыдущий вход и
  // ограничивает список восемью. После списка пишет активную запись, чтобы новый вход можно было
  // найти при следующем запуске.
  func save(_ profile: NetworkProfile) throws {
    gate.lock()
    defer { gate.unlock() }
    let next = try checked(profile)
    var values = try remembered()
    if let prior = try current(), !values.contains(where: { $0.userId == prior.userId }) {
      values.insert(prior, at: 0)
    }
    values = [next] + values.filter { $0.userId != next.userId }
    values = Array(values.prefix(8))
    try write(JSONEncoder().encode(values), account: "accounts")
    try write(JSONEncoder().encode(next), account: "device")
  }
  // Убирает активный аккаунт под блокировкой, если он есть. Без этого после выхода приложение
  // могло бы снова использовать сохранённый вход.
  func removeActive() throws {
    gate.lock()
    defer { gate.unlock() }
    guard let active = try current() else { return }
    try removeAccount(active.userId)
  }
  // Удаляет сохранённый вход по номеру владельца под общей блокировкой. Это позволяет обработать
  // удаление даже когда открыт другой аккаунт.
  func forget(_ userID: Int64) throws {
    gate.lock()
    defer { gate.unlock() }
    try removeAccount(userID)
  }
  // Убирает владельца из запомненных и удаляет активную запись только если она ему принадлежит.
  // Чужой активный вход при этом остаётся доступным.
  private func removeAccount(_ userID: Int64) throws {
    let remaining = try remembered().filter { $0.userId != userID }
    try write(JSONEncoder().encode(remaining), account: "accounts")
    guard try current()?.userId == userID else { return }
    let status = SecItemDelete(query("device") as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NetworkCredentialFailure(status: status)
    }
  }
}
enum NetworkCredentials {
  private static let store = NetworkCredentialStore(
    service: (Bundle.main.bundleIdentifier ?? "dev.kirill.kandinsky.chat") + ".network.v1")
  // Даёт остальному приложению прочитать активный вход через общее защищённое хранилище.
  // Отдельные копии ключа для этого не нужны.
  static func load() throws -> NetworkProfile? { try store.load() }
  // Читает последний открытый чат по номеру владельца. Номер владельца нужен, чтобы разные
  // аккаунты не делили одну настройку.
  static func selectedChat(for user: Int64) -> ChatID? {
    (UserDefaults.standard.object(forKey: "studio.selectedChat.\(user)") as? NSNumber)?.int64Value
  }

  // Запоминает чат конкретного аккаунта или очищает отметку при удалении. Иначе запуск мог бы
  // восстановить уже закрытую историю.
  static func selectChat(_ id: ChatID?, for user: Int64) {
    UserDefaults.standard.set(id, forKey: "studio.selectedChat.\(user)")
  }

  // Передаёт новый вход защищённому хранилищу, которое обновляет активный и запомненные профили
  // одним порядком.
  static func save(_ profile: NetworkProfile) throws { try store.save(profile) }
  // Выдаёт список сохранённых аккаунтов из общего защищённого хранилища. Это позволяет экрану
  // смены входа пользоваться теми же записями, что и запуск.
  static func profiles() throws -> [NetworkProfile] { try store.profiles() }
  // Передаёт выход системному хранилищу. Удаление только состояния экрана оставило бы ключ на
  // телефоне.
  static func removeActive() throws { try store.removeActive() }

  /// Эту отметку нужно создать до удаления файлов, чтобы незавершённую очистку можно было продолжить после
  /// перезапуска.
  // Ставит отметку до удаления локальных данных. Если приложение закроется, следующий запуск
  // знает, чью очистку продолжить.
  static func stageErasure(_ userID: Int64, root: URL) throws {
    try LocalAccountErasure.stage(userID, root: root)
  }
  // Продолжает отмеченные удаления и передаёт очистке доступ к защищённым записям. Только так
  // удаляются и папка владельца, и его сохранённый вход.
  static func finishErasures(root: URL) throws {
    try LocalAccountErasure.finish(root: root, forget: store.forget)
  }
}

enum LocalAccountErasure {
  // Строит путь к папке отметок рядом с папками аккаунтов. Один путь нужен и записи, и
  // продолжению очистки.
  private static func queue(in root: URL) -> URL {
    root.appendingPathComponent("erased-accounts", isDirectory: true)
  }

  /// Записывает пустую отметку с его номером заменой файла целиком, чтобы следующий запуск мог продолжить
  /// удаление.
  // Проверяет номер и записывает пустую отметку заменой файла целиком. Такая запись остаётся
  // пригодной для повторной очистки после сбоя.
  static func stage(_ userID: Int64, root: URL) throws {
    guard userID > 0 else { throw RepoError.invalidInput }
    let queue = queue(in: root)
    try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
    try Data().write(to: queue.appendingPathComponent(String(userID)), options: .atomic)
  }

  // Читает отметки с допустимыми номерами, убирает вход, выбор чата и папку каждого владельца.
  // Удаляет отметку последней, чтобы прерывание не спрятало незаконченную работу.
  static func finish(root: URL, forget: (Int64) throws -> Void) throws {
    let manager = FileManager.default
    let queue = queue(in: root)
    guard manager.fileExists(atPath: queue.path) else { return }
    for marker in try manager.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil) {
      guard let id = Int64(marker.lastPathComponent), id > 0,
        marker.lastPathComponent == String(id)
      else { continue }
      try forget(id)
      NetworkCredentials.selectChat(nil, for: id)
      let owned = root.appendingPathComponent("net-v1-u\(id)", isDirectory: true)
      if manager.fileExists(atPath: owned.path) { try manager.removeItem(at: owned) }
      try manager.removeItem(at: marker)
    }
  }
}
