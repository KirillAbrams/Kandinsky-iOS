import UIKit
import AVFoundation
@MainActor final class PhotoCaptureController: NSObject, AVCapturePhotoCaptureDelegate {
  private let media: MediaStore, admission: MediaAdmission
  private let prepareStudioPhoto: Bool
  private let session = AVCaptureSession(), output = AVCapturePhotoOutput()
  private let queue = DispatchQueue(label: "Kandinsky.photo.camera", qos: .userInitiated)
  private var lease: CaptureLease?, request: MediaCancellation?
  private var modal: UIViewController?, preview: AVCaptureVideoPreviewLayer?
  private var completion: ((Result<AttachmentDraft, Error>) -> Void)?
  private var data: Data?, captureError: Error?
  private var backgroundObserver: NSObjectProtocol?
  private var capturing = false, cancelled = false, closing = false
  init(media: MediaStore, admission: MediaAdmission, prepareStudioPhoto: Bool = false) {
    self.media = media
    self.admission = admission
    self.prepareStudioPhoto = prepareStudioPhoto
  }
  func open(
    from presenter: UIViewController, completion: @escaping (Result<AttachmentDraft, Error>) -> Void
  ) {
    self.completion = completion
    guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    else {
      finish(.failure(MediaError.unavailable))
      return
    }
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
    func authorized(_ granted: Bool) {
      guard !closing else { return }
      guard granted else {
        finish(.failure(MediaError.permissionDenied))
        return
      }
      request = admission.acquire(.photo) { [self] result in
        result.fold(
          success: { lease in
            self.lease = lease
            self.configure(presenter)
          }, failure: { self.finish(.failure($0)) })
      }
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: authorized(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { value in
        DispatchQueue.main.async { authorized(value) }
      }
    default: authorized(false)
    }
  }
  private func configure(_ presenter: UIViewController) {
    guard
      let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    else {
      finish(.failure(MediaError.unavailable))
      return
    }
    let session = self.session, output = self.output
    queue.async { [self] in
      do {
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
          session.commitConfiguration()
          throw MediaError.unavailable
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async { self.show(presenter) }
      } catch { DispatchQueue.main.async { self.finish(.failure(error)) } }
    }
  }
  private func show(_ presenter: UIViewController) {
    guard !closing else { return }
    let vc = UIViewController()
    vc.view.backgroundColor = .black
    vc.modalPresentationStyle = .fullScreen
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = vc.view.bounds
    vc.view.layer.addSublayer(layer)
    preview = layer
    let cancel = UIButton(type: .system)
    cancel.setTitle("Отмена", for: .normal)
    cancel.frame = CGRect(x: 16, y: 64, width: 84, height: 48)
    cancel.accessibilityIdentifier = "capture.cancel"
    cancel.addAction(
      UIAction { [self] _ in
        cancelled = true
        if !capturing { finish(.failure(MediaError.cancelled)) }
      }, for: .touchUpInside)
    let shutter = UIButton(type: .system)
    shutter.setTitle("●", for: .normal)
    shutter.titleLabel?.font = .systemFont(ofSize: 66)
    shutter.tintColor = .white
    shutter.frame = CGRect(
      x: vc.view.bounds.midX - 50, y: vc.view.bounds.height - 130, width: 100, height: 100)
    shutter.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]
    shutter.accessibilityIdentifier = "capture.photo"
    shutter.addAction(
      UIAction { [self] _ in
        guard !capturing, !closing else { return }
        capturing = true
        shutter.isEnabled = false
        output.capturePhoto(
          with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]),
          delegate: self)
      }, for: .touchUpInside)
    vc.view.addSubview(cancel)
    vc.view.addSubview(shutter)
    modal = vc
    presenter.present(vc, animated: true)
  }
  nonisolated func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
  ) {
    let bytes = photo.fileDataRepresentation()
    DispatchQueue.main.async {
      self.data = bytes
      self.captureError = error
    }
  }
  /// Удаляет временный файл, а при позднем завершении после закрытия отбрасывает неопубликованный импорт.
  nonisolated func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?
  ) {
    DispatchQueue.main.async { [self] in
      capturing = false
      if cancelled {
        finish(.failure(MediaError.cancelled))
        return
      }
      guard error == nil, captureError == nil, let data else {
        finish(.failure(error ?? captureError ?? MediaError.corrupt))
        return
      }
      Task {
        do {
          let temp = try AttachmentScratch.file(in: media.store.root, extension: "jpg")
          defer { try? FileManager.default.removeItem(at: temp) }
          try data.write(to: temp, options: .atomic)
          let draft: AttachmentDraft
          if prepareStudioPhoto {
            draft = try await media.stageStudioPhoto(sourceURL: temp)
          } else {
            draft = try await media.stage(sourceURL: temp, mime: "image/jpeg")
          }
          guard !closing else {
            try await media.discardUnpublishedImport(draft)
            return
          }
          finish(.success(draft))
        } catch {
          finish(.failure(error))
        }
      }
    }
  }
  /// Если фото уже снимается, ждём ответа камеры. Иначе закрытие экрана могло бы прервать запись файла.
  func cancel() {
    cancelled = true
    if !capturing { finish(.failure(MediaError.cancelled)) }
  }
  private func finish(_ result: Result<AttachmentDraft, Error>) {
    guard !closing else { return }
    closing = true
    if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    backgroundObserver = nil
    request?.cancel()
    let session = self.session
    queue.async { [self] in
      if session.isRunning { session.stopRunning() }
      session.beginConfiguration()
      session.inputs.forEach { session.removeInput($0) }
      session.outputs.forEach { session.removeOutput($0) }
      session.commitConfiguration()
      DispatchQueue.main.async { [self] in
        preview?.session = nil
        preview?.removeFromSuperlayer()
        preview = nil
        let done = { [self] in
          lease?.release()
          lease = nil
          data = nil
          let callback = completion
          completion = nil
          callback?(result)
        }
        if let modal { modal.dismiss(animated: true, completion: done) } else { done() }
      }
    }
  }
}
private extension Result {
  func fold(success: (Success) -> Void, failure: (Failure) -> Void) {
    switch self {
    case let .success(v): success(v)
    case let .failure(e): failure(e)
    }
  }
}
