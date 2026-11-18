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
  init(service: String) { self.service = service }
  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }
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
  private func checked(_ profile: NetworkProfile) throws -> NetworkProfile {
    guard profile.userId > 0, profile.deviceId.count <= 64, profile.token.count == 64,
      profile.token.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw RepoError.corrupt }
    return profile
  }
  private func current() throws -> NetworkProfile? {
    try read("device").map { try checked(JSONDecoder().decode(NetworkProfile.self, from: $0)) }
  }
  private func remembered() throws -> [NetworkProfile] {
    let values =
      try read("accounts").map { try JSONDecoder().decode([NetworkProfile].self, from: $0) } ?? []
    guard values.count <= 8 else { throw RepoError.corrupt }
    return try values.map(checked)
  }
  func load() throws -> NetworkProfile? {
    gate.lock()
    defer { gate.unlock() }
    return try current()
  }
  func profiles() throws -> [NetworkProfile] {
    gate.lock()
    defer { gate.unlock() }
    let values = try remembered()
    guard let current = try current() else { return values }
    return [current] + values.filter { $0.userId != current.userId }
  }
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
  func removeActive() throws {
    gate.lock()
    defer { gate.unlock() }
    guard let active = try current() else { return }
    try removeAccount(active.userId)
  }
  func forget(_ userID: Int64) throws {
    gate.lock()
    defer { gate.unlock() }
    try removeAccount(userID)
  }
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
  static func load() throws -> NetworkProfile? { try store.load() }
  static func selectedChat(for user: Int64) -> ChatID? {
    (UserDefaults.standard.object(forKey: "studio.selectedChat.\(user)") as? NSNumber)?.int64Value
  }

  static func selectChat(_ id: ChatID?, for user: Int64) {
    UserDefaults.standard.set(id, forKey: "studio.selectedChat.\(user)")
  }

  static func save(_ profile: NetworkProfile) throws { try store.save(profile) }
  static func profiles() throws -> [NetworkProfile] { try store.profiles() }
  static func removeActive() throws { try store.removeActive() }

  /// Эту отметку нужно создать до удаления файлов, чтобы незавершённую очистку можно было продолжить после
  /// перезапуска.
  static func stageErasure(_ userID: Int64, root: URL) throws {
    try LocalAccountErasure.stage(userID, root: root)
  }
  static func finishErasures(root: URL) throws {
    try LocalAccountErasure.finish(root: root, forget: store.forget)
  }
}

enum LocalAccountErasure {
  private static func queue(in root: URL) -> URL {
    root.appendingPathComponent("erased-accounts", isDirectory: true)
  }

  /// Записывает пустую отметку с его номером заменой файла целиком, чтобы следующий запуск мог продолжить
  /// удаление.
  static func stage(_ userID: Int64, root: URL) throws {
    guard userID > 0 else { throw RepoError.invalidInput }
    let queue = queue(in: root)
    try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
    try Data().write(to: queue.appendingPathComponent(String(userID)), options: .atomic)
  }

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
