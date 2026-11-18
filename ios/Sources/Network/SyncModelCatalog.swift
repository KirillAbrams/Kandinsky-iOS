import Foundation

extension NetworkSync {
  func studioModels() async throws -> [StudioModel] {
    struct Catalog: Decodable { let models: [StudioModel] }
    return try JSONDecoder().decode(Catalog.self, from: await api.json("/v1/kandinsky/models"))
      .models
  }
}
