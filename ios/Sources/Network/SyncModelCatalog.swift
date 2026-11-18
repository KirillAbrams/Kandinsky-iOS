// Загружает список моделей и доступных настроек с сервера. Выбор в приложении следует за текущими
// возможностями сервера.

import Foundation

extension NetworkSync {
  // Читает сетевой ответ и извлекает из него модели в форме, которую использует экран настроек.
  // Ошибка чтения передаётся вызывающему коду вместо показа пустого списка как успешного.
  func studioModels() async throws -> [StudioModel] {
    struct Catalog: Decodable { let models: [StudioModel] }
    return try JSONDecoder().decode(Catalog.self, from: await api.json("/v1/kandinsky/models"))
      .models
  }
}
