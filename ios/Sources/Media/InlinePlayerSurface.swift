// Показывает встроенное видео и временный кадр поверх него. Чёткий кадр остаётся до готовности
// проигрывателя и освобождается при закрытии.

import UIKit
import AVFoundation

@MainActor final class InlinePlayerSurface: UIView {
  private weak var coordinator: MediaCoordinator?
  private let video = AVPlayerLayer(), poster = UIImageView()
  private var posterFrame: PreparedImage?
  private var readyObservation: NSKeyValueObservation?
  var showsGalleryPageBehind = false {
    // Пересчитывает фон при переходе над страницей просмотра. Если значение прежнее, лишняя
    // перерисовка не нужна.
    didSet { if oldValue != showsGalleryPageBehind { update() } }
  }
  var studioPreviewBackground = false {
    // Меняет оформление подложки, только когда её режим изменился. Это не затрагивает текущий
    // кадр.
    didSet { if oldValue != studioPreviewBackground { update() } }
  }
  var hasVideoFrame: Bool { video.player?.currentItem != nil && video.isReadyForDisplay }
  var circular = false {
    // Переключает заполнение рамки между кругом и обычным видео и просит пересчитать размеры.
    // Иначе края кадра остались бы от прежней формы.
    didSet {
      video.videoGravity = circular ? .resizeAspectFill : .resizeAspect
      update()
      setNeedsLayout()
    }
  }
  // Создаёт слой видео и картинку поверх него, затем ждёт готовности именно текущего ролика.
  // Запоздалое событие другого ролика не должно убирать картинку.
  init(coordinator: MediaCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    backgroundColor = .black
    layer.cornerRadius = 12
    layer.masksToBounds = true
    layer.addSublayer(video)
    video.videoGravity = .resizeAspect
    isUserInteractionEnabled = false
    poster.contentMode = .scaleAspectFill
    poster.clipsToBounds = true
    addSubview(poster)
    readyObservation = video.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
      guard layer.isReadyForDisplay, let item = layer.player?.currentItem else { return }
      let target = self?.coordinator?.currentMessageID
      DispatchQueue.main.async { [weak self] in
        guard let self, self.coordinator?.currentMessageID == target,
          self.video.player?.currentItem === item
        else { return }
        self.setPoster(nil)
      }
    }
  }
  // Отклоняет создание из сохранённой разметки. Слои нужно собрать вместе с владельцем
  // проигрывателя.
  required init?(coder: NSCoder) { fatalError() }
  // Принимает готовый кадр и освобождает прежний. Маленькая размытая картинка не заменяет уже
  // показанную чёткую, иначе при возврате видно ухудшение.
  func setPoster(_ frame: PreparedImage?) {
    if frame?.isTinyPreview == true, posterFrame != nil, posterFrame?.isTinyPreview == false {
      frame?.close()
      return
    }
    if frame == nil && posterFrame == nil && poster.image == nil { return }
    poster.image = nil
    posterFrame?.close()
    posterFrame = frame
    poster.image = frame?.image.map { UIImage(cgImage: $0) }
    poster.isHidden = frame == nil
  }
  // Подключает слой к существующему проигрывателю и обновляет оформление. Отдельный проигрыватель
  // для этого слоя не создаётся.
  func attach() {
    coordinator?.attach(output: video)
    update()
  }
  // Запоминает место просмотра, отсоединяет слой и освобождает показанный кадр. При возврате
  // владелец сможет восстановить позицию.
  func detach() {
    coordinator?.rememberPlayback()
    coordinator?.detach(output: video)
    setPoster(nil)
  }
  // Выбирает прозрачную или сплошную подложку и показывает картинку только при наличии кадра.
  // Изменение фона не требует заново открывать файл.
  func update() {
    let transparent = circular || showsGalleryPageBehind
    isOpaque = !transparent
    backgroundColor = transparent ? .clear : studioPreviewBackground ? KandinskyPalette.studioSheet : .black
    poster.isHidden = posterFrame == nil
    setNeedsLayout()
  }
  // Подгоняет слой и картинку под одни границы, а для круглого видео обрезает углы. Совпадение
  // размеров избавляет от скачка при смене кадра.
  override func layoutSubviews() {
    super.layoutSubviews()
    if circular {
      let size = min(bounds.width, bounds.height)
      video.frame = CGRect(x: 0, y: 0, width: size, height: size)
      video.cornerRadius = size / 2
      video.masksToBounds = true
    } else {
      video.frame = bounds
      video.cornerRadius = 0
      video.masksToBounds = false
    }
    poster.frame = video.frame
    poster.contentMode = circular ? .scaleAspectFill : .scaleAspectFit
    poster.layer.cornerRadius = circular ? min(video.frame.width, video.frame.height) / 2 : 0
  }
}
