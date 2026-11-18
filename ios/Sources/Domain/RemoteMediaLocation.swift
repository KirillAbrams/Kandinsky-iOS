import Foundation

struct RemoteMediaLocation: Codable, Equatable, Sendable {
  let blobID: String
  let previewBlobID: String?
  let mime: String
  let byteSize: Int64

  static func validBlobID(_ value: String) -> Bool {
    [32, 64].contains(value.utf8.count)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  var isValid: Bool {
    Self.validBlobID(blobID)
      && (previewBlobID.map(Self.validBlobID) ?? true)
      && (1...67_108_864).contains(byteSize)
  }
}
