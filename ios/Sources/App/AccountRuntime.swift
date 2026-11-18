import Foundation

@MainActor final class AccountRuntime {
  let store: SQLiteStore
  let repository: ChatRepository
  let network: NetworkSync
  private(set) var media: MediaStore?
  private(set) var playback: MediaCoordinator?

  private init(store: SQLiteStore, profile: NetworkProfile) {
    self.store = store
    let local = SQLiteChatRepository(store: store, journal: NetworkJournal(userID: profile.userId))
    let sync = NetworkSync(profile: profile, store: store, local: local)
    network = sync
    repository = NetworkChatRepository(
      local: local, wake: { [weak sync] in Task { @MainActor in sync?.kick() } })
  }

  static func restoreProfile(root: URL, invitation: String?) async throws -> NetworkProfile? {
    try await Task.detached(priority: .userInitiated) {
      () async throws -> NetworkProfile? in
      try NetworkCredentials.finishErasures(root: root)
      if let stored = try NetworkCredentials.load() { return stored }
      let arguments = ProcessInfo.processInfo.arguments
      let supplied =
        invitation
        ?? arguments.firstIndex(of: "--network-invitation").flatMap {
          $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
      guard let supplied else { return nil }
      let api = NetworkAPI(profile: nil)
      defer { api.close() }
      let session = try await api.enroll(invitation: supplied, name: "iOS Kandinsky")
      try NetworkCredentials.save(session)
      return session
    }.value
  }

  static func open(root: URL, profile: NetworkProfile) async throws -> AccountRuntime {
    let name = "net-v1-u" + String(profile.userId)
    let store = try await SQLiteStore.open(root: root.appendingPathComponent(name))
    do {
      try await store.perform { db in
        try NetworkSchema.install(db)
      }
      return AccountRuntime(store: store, profile: profile)
    } catch {
      try? await store.close()
      throw error
    }
  }

  func prepareMedia(admission: MediaAdmission) async throws {
    let media = MediaStore(store: store, studioOriginals: true)
    self.media = media
    let remote = NetworkMedia(store: store, api: network.api, originalLimitMiB: 256)
    network.studioMedia = remote
    network.onStudioMediaEvicted = { [weak media] in media?.releaseIdleImages() }
    media.remoteThumbnailProvider = remote
    media.remoteFile = { try remote.resolve($0, preview: $1, token: $2) }
    media.remotePlayback = { try remote.playback($0, token: $1) }
    media.pendingReferences = NetworkMedia.pendingReferences
    try await media.recover()
    if self.media === media {
      playback = MediaCoordinator(admission: admission, media: media)
    }
  }

  func closeServices() {
    network.close()
    playback?.close()
    playback = nil
    media?.close()
    media = nil
  }
}
