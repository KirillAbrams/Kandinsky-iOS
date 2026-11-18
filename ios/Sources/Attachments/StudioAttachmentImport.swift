import UIKit
import PhotosUI
import UniformTypeIdentifiers

private final class GrantedGalleryFile: @unchecked Sendable {
  let url: URL, mime: String
  init(url: URL, mime: String) {
    self.url = url
    self.mime = mime
  }
  func close() { try? FileManager.default.removeItem(at: url) }
  deinit { close() }
}
@MainActor enum StudioAttachmentImport {
  static func stage(_ provider: NSItemProvider, media: MediaStore) async throws -> AttachmentDraft {
    let file = try await copyGrantedFile(provider, root: media.store.root)
    defer { file.close() }
    if file.mime.hasPrefix("image/") {
      return try await media.stageStudioPhoto(sourceURL: file.url)
    }
    return try await media.stageSelection(sourceURL: file.url, mime: file.mime)
  }
  /// Доступ к файлу из системного окна выбора временный. Копируем файл, пока этот доступ открыт.
  nonisolated private static func copyGrantedFile(_ provider: NSItemProvider, root: URL) async throws
    -> GrantedGalleryFile
  {
    let cancel = MediaCancellation(), delivered = MediaCancellation(),
      providerStop = MediaCancellation()
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { reply in
          cancel.onCancel {
            providerStop.cancel()
            if delivered.finish() { reply.resume(throwing: MediaError.cancelled) }
          }
          DispatchQueue.global(qos: .utility).async {
            guard !cancel.isCancelled else { return }
            let type =
              provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
              ? UTType.movie : UTType.image
            let progress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) {
              url, error in
              let result = Result<GrantedGalleryFile, Error> {
                guard !cancel.isCancelled else { throw MediaError.cancelled }
                guard let url, url.isFileURL else { throw error ?? MediaError.unavailable }
                let ext = url.pathExtension.lowercased(),
                  types = [
                    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                    "heic": "image/heic", "heif": "image/heif", "gif": "image/gif",
                    "mp4": "video/mp4", "mov": "video/quicktime"
                  ]
                guard let mime = types[ext],
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...64 * 1024 * 1024).contains(size)
                else { throw MediaError.unavailable }
                let copy = try AttachmentScratch.file(in: root, extension: ext)
                guard
                  FileManager.default.createFile(
                    atPath: copy.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw MediaError.io }
                let file = GrantedGalleryFile(url: copy, mime: mime),
                  input = try FileHandle(forReadingFrom: url),
                  output = try FileHandle(forWritingTo: copy)
                defer {
                  try? input.close()
                  try? output.close()
                }
                var bytes = 0
                while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                  guard !cancel.isCancelled else { throw MediaError.cancelled }
                  bytes += chunk.count
                  guard bytes <= 64 * 1024 * 1024 else { throw MediaError.unavailable }
                  try output.write(contentsOf: chunk)
                }
                guard bytes > 0 else { throw MediaError.corrupt }
                try output.close()
                return file
              }
              if delivered.finish() {
                _ = cancel.finish()
                reply.resume(with: result)
              } else if case let .success(file) = result {
                file.close()
              }
            }
            providerStop.onCancel { progress.cancel() }
          }
        }
      }, onCancel: { cancel.cancel() })
  }
}
