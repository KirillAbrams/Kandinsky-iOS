// Восстанавливает местный черновик, загружает исходники и чистит сохранённые копии после удаления
// на сервере. Каждый черновик имеет свой номер, чтобы позднее действие не затронуло другой.

import Foundation

extension NetworkSync {
  // Читает текущий черновик через местную базу. Это позволяет восстановить незаконченный ввод
  // после возврата к экрану.
  func savedStudioDraft() async throws -> StudioDraftRecord? {
    try await store.perform { try StudioDraftStorage.load($0) }
  }
  // Одной записью меняет текущий черновик и отдаёт предыдущий. Иначе параллельное открытие могло
  // бы затереть ввод до того, как экран сохранит старую запись.
  func beginStudioDraft(_ record: StudioDraftRecord) async throws -> StudioDraftRecord? {
    try await store.perform { db in
      try db.transaction {
        let previous = try StudioDraftStorage.load(db)
        try StudioDraftStorage.write(db, record)
        return previous
      }
    }
  }
  // Сверяет номер активного черновика и записывает ввод только при совпадении. Запоздалое
  // сохранение с закрытого экрана не должно перезаписать новый текст.
  func saveStudioDraft(_ draft: Draft, identity: UUID) async throws {
    try await store.perform { db in
      try db.transaction {
        guard try StudioDraftStorage.load(db)?.identity == identity else { return }
        try StudioDraftStorage.write(db, StudioDraftRecord(identity: identity, draft: draft))
      }
    }
  }
  // Удаляет запись, только если ещё открыт тот же черновик. Старое завершение отправки не может
  // убрать черновик, начатый позже.
  func finishStudioDraft(identity: UUID) async throws {
    try await store.perform { db in
      try db.transaction {
        guard try StudioDraftStorage.load(db)?.identity == identity else { return }
        try db.execute("DELETE FROM net_state WHERE key=?", [.text(StudioDraftStorage.key)])
      }
    }
  }

  // Читает порцию текущих загрузок и отсекает лишние, неверные или повторные строки. Только после
  // проверки обновляет видимые сведения, чтобы одно плохое событие не испортило список.
  func acceptStudioTransfers(_ data: Data) throws {
    struct Page: Decodable { let uploads: [StudioTransfer] }
    let rows = try JSONDecoder().decode(Page.self, from: data).uploads
    guard rows.count <= 8, rows.allSatisfy(\.isValid), Set(rows.map(\.id)).count == rows.count
    else {
      throw RepoError.corrupt
    }
    studioTransfers = rows
    onStudioTransfersChanged?()
  }

  // Проверяет, сохранился ли номер принятого файла для вложения. По этому признаку можно не
  // загружать оригинал снова после восстановления связи.
  func hasStudioUpload(_ attachmentID: String) async throws -> Bool {
    try await store.perform { db in
      try db.scalar("SELECT count(*) FROM net_uploads WHERE attachmentID=?", [.text(attachmentID)])
        > 0
    }
  }

  // Читает список недавних принятых исходников. Экран может предложить их для повторного выбора
  // без поиска по местным файлам.
  func recentStudioUploads() async throws -> [StudioUpload] {
    struct Page: Decodable { let uploads: [StudioUpload] }
    return try JSONDecoder().decode(Page.self, from: await api.json("/v1/kandinsky/uploads/recent"))
      .uploads
  }
  // Сопоставляет номер вложения с номерами оригинала и копии. При повторной отправке эти номера
  // остаются доступны даже после закрытия приложения.
  func rememberStudioUpload(attachmentID: String, blobID: String, previewID: String? = nil)
    async throws
  {
    _ = try await store.perform { db in
      try db.execute(
        "INSERT OR REPLACE INTO net_uploads(attachmentID,blobID,previewBlobID) VALUES(?,?,?)",
        [.text(attachmentID), .text(blobID), previewID.map(SQLValue.text) ?? .null])
    }
  }
  // Передаёт оригинал с постоянным номером и показывает ход загрузки. Для фото после проверки
  // отмены делает копию и сохраняет оба номера, чтобы прерванная задача не продолжала подготовку.
  func uploadStudioSource(
    _ draft: AttachmentDraft, chat: ChatID, progress: @escaping @Sendable (Double) -> Void
  )
    async throws
  {
    let root = store.root
    let file = try MediaStore.fileURL(root: root, relative: draft.relativePath)
    let result = try await api.upload(
      file: file, mime: draft.mime, id: draft.id.lowercased(), studioSource: true, chat: chat,
      progress: progress)
    try Task.checkCancellation()
    if draft.mime.hasPrefix("image/") {
      let blob = try result.string("blobId")
      let preview = try await NetworkPreview.upload(
        root: root, attachment: draft, api: api, parent: blob)
      try Task.checkCancellation()
      try await rememberStudioUpload(attachmentID: draft.id, blobID: blob, previewID: preview)
    }
  }

  // Читает отметки удаления небольшими порциями и убирает копии вне потока экрана. Стирает
  // отметку только после очистки и при прежнем значении, иначе параллельное обновление могло бы
  // потеряться.
  func drainRemovedStudioMedia() {
    guard !closed, removalTask == nil, let media = studioMedia else { return }
    removalTask = Task { [weak self] in
      guard let self else { return }
      defer { self.removalTask = nil }
      while !Task.isCancelled {
        do {
          let batch = try await store.perform { db in
            try db.rows("SELECT key,value FROM net_state WHERE key LIKE 'studioRemoved:%' LIMIT 16")
              .compactMap { row in
                StudioMediaRemoval(
                  blob: String(row["key"]!.string.dropFirst(StudioMediaRemoval.prefix.count)),
                  preview: row["value"]!.string)
              }
          }
          guard !batch.isEmpty else { return }
          try await Task.detached(priority: .utility) {
            for item in batch { try media.removeCached(item) }
          }.value
          if !closed { onStudioMediaEvicted?() }
          try await store.perform { db in
            for item in batch {
              try db.execute(
                "DELETE FROM net_state WHERE key=? AND value=?",
                [.text(item.key), .text(item.preview)])
            }
          }
        } catch { return }
      }
    }
  }
}

enum StudioDraftStorage {
  static let key = "studio.newDraft"
  // Читает запись черновика и проверяет её размер до разбора. Повреждённая или слишком большая
  // запись не должна попасть на экран как обычный черновик.
  static func load(_ db: SQLiteConnection) throws -> StudioDraftRecord? {
    guard
      let raw = try db.rows("SELECT value FROM net_state WHERE key=?", [.text(key)]).first?[
        "value"]?.string
    else {
      return nil
    }
    guard raw.utf8.count <= 262144 else { throw RepoError.corrupt }
    return try JSONDecoder().decode(StudioDraftRecord.self, from: Data(raw.utf8))
  }
  // Готовит запись с номером и содержимым и проверяет размер до сохранения. Так ввод не может
  // бесконтрольно увеличивать служебную запись базы.
  static func write(_ db: SQLiteConnection, _ record: StudioDraftRecord) throws {
    let data = try JSONEncoder().encode(record)
    guard data.count <= 262144 else { throw RepoError.invalidInput }
    try db.execute(
      "INSERT OR REPLACE INTO net_state(key,value) VALUES(?,?)",
      [.text(key), .text(String(decoding: data, as: UTF8.self))])
  }
}
