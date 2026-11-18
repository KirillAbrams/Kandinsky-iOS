import Foundation

enum AppDataRoot {
  private static func excludeFromBackup(_ directory: URL) throws -> URL {
    var location = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try location.setResourceValues(values)
    return location
  }

  /// Переносим старую папку целиком, чтобы сохранить вместе базу, черновики и незавершённые операции.
  static func resolve(_ base: URL) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    let target = base.appendingPathComponent("Kandinsky", isDirectory: true)
    if manager.fileExists(atPath: target.path) {
      let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      return try excludeFromBackup(target)
    }
    let children = try manager.contentsOfDirectory(
      at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    let candidates = try children.filter { child in
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
      return try containsSavedState(child)
    }
    guard candidates.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
    if let previous = candidates.first {
      try manager.moveItem(at: previous, to: target)
    } else {
      try manager.createDirectory(at: target, withIntermediateDirectories: true)
    }
    return try excludeFromBackup(target)
  }

  private static func containsSavedState(_ root: URL) throws -> Bool {
    let manager = FileManager.default
    for child in try manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) {
      guard
        child.lastPathComponent.range(
          of: "^(chat-v1|net-v1-u[0-9]+|test-[A-Fa-f0-9-]+)$", options: .regularExpression
        ) != nil
      else { continue }
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      let database = child.appendingPathComponent("chat.sqlite3")
      guard manager.fileExists(atPath: database.path) else { continue }
      let file = try database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if file.isRegularFile == true && file.isSymbolicLink != true { return true }
    }
    let queue = root.appendingPathComponent("erased-accounts", isDirectory: true)
    guard manager.fileExists(atPath: queue.path) else { return false }
    let values = try queue.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
    for marker in try manager.contentsOfDirectory(
      at: queue, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    ) {
      guard let id = Int64(marker.lastPathComponent), id > 0,
        marker.lastPathComponent == String(id)
      else { continue }
      let file = try marker.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
      ])
      if file.isRegularFile == true && file.isSymbolicLink != true && file.fileSize == 0 {
        return true
      }
    }
    return false
  }
}
