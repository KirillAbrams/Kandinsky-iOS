import UIKit

enum MessageAction { case copy }

@MainActor final class ConversationUIController {
  private weak var parent: UIView?
  private let actions: MessageActions
  var generationAction: ((MessageID, StudioGenerationAction, UUID?) async throws -> Void)?
  var retrySlotAction: ((MessageID, StudioGeneration.Slot, UUID) async throws -> Void)?
  var deleteGenerationContent: ((MessageID, String?) async throws -> Void)?
  var reportGeneration: ((MessageID, StudioReportReason) async throws -> Void)?
  private let state: ConversationState
  private var generationActionsInFlight = Set<MessageID>()
  init(
    parent: UIView, chatID: ChatID, repository: ChatRepository, state: ConversationState,
    onDelta: @escaping (MessageDelta) -> Void
  ) {
    self.parent = parent
    self.state = state
    actions = MessageActions(chatID: chatID, repository: repository, state: state)
    actions.onDelta = onDelta
  }
  private var presenter: UIViewController? {
    var responder: UIResponder? = parent
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }
  private func canCancel(_ message: Message) -> Bool {
    message.direction == .outgoing && [.pending, .failed].contains(message.delivery)
  }
  func perform(_ kind: MessageAction, message: Message) {
    switch kind {
    case .copy: Task { do { _ = try await actions.copy(id: message.id) } catch { failed(error) } }
    }
  }
  private func confirmPendingRemoval(_ message: Message) {
    let alert = UIAlertController(
      title: "Отменить отправку?", message: "Этот запрос не будет отправлен повторно.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Оставить", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Отменить отправку", style: .destructive) { [weak self] _ in
        guard let self else { return }
        Task {
          do { _ = try await self.actions.delete(id: message.id) } catch { self.failed(error) }
        }
      })
    presenter?.present(alert, animated: true)
  }
  func menu(message: Message) {

    if message.direction == .outgoing {
      var items = [KandinskySheetAction]()
      if !message.text.isEmpty || !message.caption.isEmpty {
        items.append(
          KandinskySheetAction(title: "Копировать запрос", symbol: "doc.on.doc") { [weak self] in
            self?.perform(.copy, message: message)
          })
      }
      if canCancel(message) {
        items.append(
          KandinskySheetAction(title: "Отменить отправку", symbol: "trash", destructive: true) {
            [weak self] in self?.confirmPendingRemoval(message)
          })
      } else if deleteGenerationContent != nil {
        items.append(
          KandinskySheetAction(title: "Удалить запрос", symbol: "trash", destructive: true) {
            [weak self] in self?.confirmPromptRemoval(message)
          })
      }
      if !items.isEmpty { sheet(nil, items) }
      return
    }
    guard message.canReportStudioMedia, let reportGeneration,
      !generationActionsInFlight.contains(message.id)
    else { return }
    let items = StudioReportReason.allCases.map { reason in
      KandinskySheetAction(title: reason.title, symbol: "flag") { [weak self] in
        guard let self, self.generationActionsInFlight.insert(message.id).inserted else { return }
        Task {
          defer { self.generationActionsInFlight.remove(message.id) }
          do {
            try await reportGeneration(message.id, reason)
            self.reportFeedback("Жалоба отправлена", nil)
          } catch { self.reportFeedback("Жалобу не удалось отправить", "Попробуйте ещё раз.") }
        }
      }
    }
    sheet("Пожаловаться на результат", items)
    return

  }
  func retrySlot(_ message: MessageID, slot: StudioGeneration.Slot) {
    guard let retrySlotAction, let operation = state.beginSlotRetry(slot) else {
      return
    }
    Task { [weak self, state] in
      defer { state.finishSlotRetry(slot.id) }
      do { try await retrySlotAction(message, slot, operation) } catch { self?.failed(error) }
    }
  }
  // Один запрос на удаление может прийти с нескольких устройств.
  func removeGenerationContent(_ message: MessageID, blob: String?) {
    guard let deleteGenerationContent, generationActionsInFlight.insert(message).inserted else {
      return
    }
    Task { [weak self] in
      guard let self else { return }
      defer { self.generationActionsInFlight.remove(message) }
      do { try await deleteGenerationContent(message, blob) } catch { self.failed(error) }
    }
  }
  private func confirmPromptRemoval(_ message: Message) {
    let alert = UIAlertController(
      title: "Удалить запрос?", message: "Запрос и его результаты исчезнут на всех устройствах.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
        self?.removeGenerationContent(message.id, blob: nil)
      })
    presenter?.present(alert, animated: true)
  }
  func performGenerationAction(_ id: MessageID, action: StudioGenerationAction) {
    guard let generationAction, generationActionsInFlight.insert(id).inserted else { return }
    Task { [weak self] in
      guard let self else { return }
      defer { self.generationActionsInFlight.remove(id) }
      do {
        try await generationAction(id, action, nil)
      } catch { self.failed(error) }
    }
  }
  private func sheet(_ title: String? = nil, _ items: [KandinskySheetAction]) {
    parent?.endEditing(true)
    presenter?.present(KandinskyActionSheet(title: title, items: items), animated: true)
  }
  private func failed(_ error: Error) {
    let alert = UIAlertController(
      title: "Действие не выполнено",
      message: "Проверьте соединение и повторите. Сообщения и черновик сохранены.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Понятно", style: .cancel))
    presenter?.present(alert, animated: true)
  }
  private func reportFeedback(_ title: String, _ detail: String?) {
    guard parent?.window != nil, let presenter, presenter.presentedViewController == nil else {
      return
    }
    let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Понятно", style: .cancel))
    presenter.present(alert, animated: true)
  }
}
