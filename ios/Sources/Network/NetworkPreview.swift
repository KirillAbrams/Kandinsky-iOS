import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NetworkPreview {
  /// Вычисляет постоянный номер передачи из номера вложения, чтобы повтор относился к той же копии.
  nonisolated static func upload(
    root: URL, attachment a: AttachmentDraft, api: NetworkAPI, parent: String? = nil
  )
    async throws -> String?
  {
    guard a.mime.hasPrefix("image/") || a.mime.hasPrefix("video/"), a.mime != "image/gif" else {
      return nil
    }
    let file = root.appendingPathComponent("media/" + a.relativePath)
    let temporary = try MediaPreviewGenerator.normalFile(
      root: root, relative: a.relativePath, file: file, mime: a.mime)
    let bytes = Array(SHA256.hash(data: Data((a.id + ":preview-v1").utf8)).prefix(16))
    let id = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
    return try await api.upload(file: temporary, mime: "image/jpeg", id: id, parent: parent).string(
      "blobId")
  }
}
