import PhotosUI
import UIKit

enum AttachmentSource { case photo, camera, video }

@MainActor final class ChatAttachmentCoordinator: NSObject, PHPickerViewControllerDelegate {
  private weak var view: UIView?
  private let state: ConversationState
  private let media: MediaStore
  private let admission: MediaAdmission
  private let presenter: () -> UIViewController?
  private let options: () -> KandinskyOptions
  private let selectOptions: (KandinskyOptions) -> Void
  private let showError: (String) -> Void
  private let previewVideo: (Attachment, (() -> Void)?, @escaping () -> Void) -> Void
  private let showProgress: (Double?) -> Void
  private let prepareDraft: () async throws -> Void
  weak var network: NetworkSync?
  private var capture: PhotoCaptureController?
  private var importTask: Task<Void, Never>?
  private var transferID: String?
  private var progress: Double = 0
  private var closed = false
  private var lastSourceAttempt: String?

  var isImporting: Bool { importTask != nil }
  private var isActive: Bool { !closed && view?.window != nil }
  private static let cameraOrGalleryError =
    "Не удалось открыть камеру или галерею. Проверьте разрешения."

  init(
    view: UIView, state: ConversationState, media: MediaStore, admission: MediaAdmission,
    presenter: @escaping () -> UIViewController?, options: @escaping () -> KandinskyOptions,
    selectOptions: @escaping (KandinskyOptions) -> Void, showError: @escaping (String) -> Void,
    previewVideo: @escaping (Attachment, (() -> Void)?, @escaping () -> Void) -> Void,
    prepareDraft: @escaping () async throws -> Void = {},
    showProgress: @escaping (Double?) -> Void
  ) {
    self.view = view
    self.state = state
    self.media = media
    self.admission = admission
    self.presenter = presenter
    self.options = options
    self.selectOptions = selectOptions
    self.showError = showError
    self.previewVideo = previewVideo
    self.showProgress = showProgress
    self.prepareDraft = prepareDraft
  }

  func resumePendingUpload(reconnected: Bool = false) {
    guard isActive, state.isReady, importTask == nil, let network,
      let source = state.draft.attachmentDrafts.first, source.mime.hasPrefix("image/")
    else { return }
    if reconnected { lastSourceAttempt = nil }
    guard lastSourceAttempt != source.id else { return }
    lastSourceAttempt = source.id
    importTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.importTask = nil
        self.state.onChange?()
      }
      guard let saved = try? await network.hasStudioUpload(source.id), !saved,
        !Task.isCancelled, self.isActive,
        self.state.draft.attachmentDrafts.first?.id == source.id
      else { return }
      await self.upload(source, media: self.media)
    }
  }

  func stopCapture() { capture?.cancel() }

  func pausePendingUpload() {
    if transferID != nil { importTask?.cancel() }
  }

  func close(discardDraft: Bool) {
    closed = true
    stopCapture()
    importTask?.cancel()
    let drafts = state.draft.attachmentDrafts
    if discardDraft && !drafts.isEmpty {
      Task { [media] in try? await media.discardUnpublishedImports(drafts) }
    }
  }

  func showPicker() {
    guard isActive, let presenter = presenter(), presenter.presentedViewController == nil,
      let network
    else { return }
    let sheet = StudioGenerationSheet(options: options())
    sheet.showAttachments { [weak self] action in
      guard let self, self.isActive, let presenter = self.presenter() else { return }
      switch action {
      case .camera: self.openCamera(from: presenter)
      case .photo, .video: self.pickFile(action, from: presenter)
      }
    }
    presenter.present(sheet, animated: true)
    Task { [weak self, weak sheet] in
      guard let uploads = try? await network.recentStudioUploads(), let sheet else { return }
      sheet.appendRecentUploads(uploads) { [weak self] upload in self?.selectRecent(upload) }
    }
  }

  private func openCamera(from presenter: UIViewController) {
    let media = self.media
    let admission = self.admission
    let capture = PhotoCaptureController(
      media: media, admission: admission, prepareStudioPhoto: true)
    self.capture = capture
    capture.open(from: presenter) { [weak self] result in
      guard let self, self.isActive else {
        if case .success(let photo) = result {
          Task { try? await media.discardUnpublishedImport(photo) }
        }
        return
      }
      self.capture = nil
      switch result {
      case .success(let photo):
        self.importTask = Task { [weak self] in
          guard let self else {
            try? await media.discardUnpublishedImport(photo)
            return
          }
          defer {
            self.importTask = nil
            self.state.onChange?()
          }
          await self.upload(photo, media: media)
        }
        self.state.onChange?()
      case .failure(let error):
        if (error as? MediaError) != .cancelled {
          self.showError(Self.cameraOrGalleryError)
        }
      }
    }
  }

  private func pickFile(_ source: AttachmentSource, from presenter: UIViewController) {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = source == .video ? .videos : .images
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  // У недавнего файла уже есть номер на сервере. Привязываем к нему местную копию.
  private func selectRecent(_ upload: StudioUpload) {
    guard isActive, importTask == nil, let network else { return }
    let media = self.media
    importTask = Task { [weak self] in
      defer {
        self?.importTask = nil
        self?.state.onChange?()
      }
      var staged: AttachmentDraft?
      do {
        let temporary = try AttachmentScratch.file(
          in: media.store.root, extension: upload.isVideo ? "mp4" : "jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let self, self.isActive else { throw CancellationError() }
        try await self.prepareDraft()
        guard let chat = self.state.chatID else { throw RepoError.invalidInput }
        _ = try await network.api.json(
          "/v1/kandinsky/threads/\(chat)/sources/" + upload.blobId, method: "POST")
        try await network.api.download(blob: upload.blobId, to: temporary, limit: upload.byteSize)
        try Task.checkCancellation()
        let file = try await media.stageSelection(sourceURL: temporary, mime: upload.mime)
        staged = file
        guard self.isActive else { throw CancellationError() }
        try Task.checkCancellation()
        try await network.rememberStudioUpload(attachmentID: file.id, blobID: upload.blobId)
        try Task.checkCancellation()
        guard self.isActive else { throw CancellationError() }
        if upload.isVideo {
          self.preview(file, media: media)
        } else {
          self.replacePhoto(file)
        }
        staged = nil
      } catch {
        if let staged { try? await media.discardUnpublishedImport(staged) }
        if !(error is CancellationError), !Task.isCancelled {
          self?.showError("Не удалось открыть файл")
        }
      }
    }
    state.onChange?()
  }

  func replacePhoto(_ photo: AttachmentDraft?) {
    if photo == nil {
      importTask?.cancel()
      transferID = nil
      showProgress(nil)
    }
    replaceSource(
      photo,
      model: photo == nil ? (options().model == "video_sr" ? "image" : options().model) : "video")
  }

  private func replaceSource(_ source: AttachmentDraft?, model: String) {
    let options = self.options()
    var draft = state.draft
    let previous = draft.attachmentDrafts
    if previous.map(\.id) == (source.map({ [$0.id] }) ?? []) { return }
    draft.attachmentDrafts = source.map { [$0] } ?? []
    let next =
      model == "video_sr"
      ? KandinskyOptions(model: model)
      : KandinskyOptions(
        model: model, aspect: options.aspect, count: options.count, seed: options.seed)
    state.editDraft(draft)
    selectOptions(next)
    if !previous.isEmpty {
      Task { [state, media] in
        try? await state.flush()
        try? await media.discardUnpublishedImports(previous)
      }
    }
  }

  // Если сеть пропала, фото остаётся в черновике для следующей отправки. Видео требует загрузки перед просмотром.
  private func upload(_ file: AttachmentDraft, media: MediaStore) async {
    let isPhoto = file.mime.hasPrefix("image/")
    let valid =
      isPhoto
      ? file.byteSize <= 20 * 1024 * 1024
      : file.mime == "video/mp4" && file.byteSize <= 20 * 1024 * 1024
        && (file.durationMs ?? 60001) <= 60000
    guard let network, !Task.isCancelled, isActive, valid else {
      try? await media.discardUnpublishedImport(file)
      if !valid {
        showError(isPhoto ? "Выберите фото до 20 МБ" : "Выберите MP4 до 20 МБ и 60 секунд")
      }
      return
    }
    lastSourceAttempt = file.id
    if isPhoto {
      do {
        replacePhoto(file)
        try await state.flush()
        try await prepareDraft()
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
        try await state.flush()
      } catch {
        if !state.draft.attachmentDrafts.contains(where: { $0.id == file.id }) {
          try? await media.discardUnpublishedImport(file)
        }
        if !Task.isCancelled { showError("Фото осталось на устройстве. Проверьте соединение.") }
        return
      }
    }
    transferID = file.id
    progress = 0
    showProgress(0)
    defer {
      transferID = nil
      showProgress(nil)
    }
    do {
      if !isPhoto { try await prepareDraft() }
      guard let chat = state.chatID else { throw RepoError.invalidInput }
      try await network.uploadStudioSource(file, chat: chat) { [weak self] value in
        Task { @MainActor in
          guard let self, self.transferID == file.id else { return }
          self.progress = max(self.progress, value)
          self.showProgress(self.progress)
        }
      }
      try Task.checkCancellation()
      guard isActive else { throw CancellationError() }
    } catch {
      if isPhoto, !Task.isCancelled, isActive,
        let failure = error as? URLError,
        [
          .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
          .cannotFindHost, .dnsLookupFailed,
        ].contains(failure.code)
      {
        replacePhoto(file)
        return
      }
      if state.draft.attachmentDrafts.contains(where: { $0.id == file.id }) {
        if Task.isCancelled || error is CancellationError || !isActive { return }
        replaceSource(nil, model: options().model)
        try? await state.flush()
      }
      try? await media.discardUnpublishedImport(file)
      if !Task.isCancelled, !(error is CancellationError) {
        showError(isPhoto ? "Не удалось загрузить фото" : "Не удалось загрузить видео")
      }
      return
    }
    if isPhoto { replacePhoto(file) } else { preview(file, media: media) }
  }

  private func preview(_ file: AttachmentDraft, media: MediaStore) {
    let attachment = Attachment(
      id: file.id, relativePath: file.relativePath, mime: file.mime, byteSize: file.byteSize,
      rawWidth: file.rawWidth, rawHeight: file.rawHeight, orientation: file.orientation,
      durationMs: file.durationMs, thumbnailKey: file.thumbnailKey)
    let duration = file.durationMs ?? 0
    let eligible =
      (1000...5100).contains(duration) && min(file.rawWidth, file.rawHeight) >= 128
      && max(file.rawWidth, file.rawHeight) <= 960 && file.rawWidth * file.rawHeight <= 960 * 540
    let enhance: (() -> Void)? =
      eligible
      ? { [weak self] in
        guard let self, let network = self.network else {
          Task { try? await media.discardUnpublishedImport(file) }
          return
        }
        self.importTask = Task { [weak self] in
          defer {
            self?.importTask = nil
            self?.state.onChange?()
          }
          let models = try? await network.studioModels()
          guard !Task.isCancelled, let self, self.isActive,
            models?.contains(where: { $0.id == "video_sr" }) == true
          else {
            try? await media.discardUnpublishedImport(file)
            if !Task.isCancelled { self?.showError("Улучшение видео сейчас недоступно") }
            return
          }
          self.replaceSource(file, model: "video_sr")
        }
        self.state.onChange?()
      } : nil
    previewVideo(attachment, enhance) { Task { try? await media.discardUnpublishedImport(file) } }
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let provider = results.first?.itemProvider
    picker.dismiss(animated: true) { [weak self] in
      guard let self, self.isActive, let provider else { return }
      let media = self.media
      self.importFile(provider, media: media)
    }
  }

  private func importFile(_ provider: NSItemProvider, media: MediaStore) {
    guard importTask == nil else { return }
    importTask = Task { [weak self] in
      defer {
        self?.importTask = nil
        self?.state.onChange?()
      }
      do {
        let file = try await StudioAttachmentImport.stage(provider, media: media)
        guard let self, !Task.isCancelled, self.isActive else {
          try? await media.discardUnpublishedImport(file)
          return
        }
        await self.upload(file, media: media)
      } catch {
        if !Task.isCancelled { self?.showError("Не удалось открыть файл") }
      }
    }
    state.onChange?()
  }

}
