import Foundation

// MARK: - Inert Feedbin client (seam 1, defence in depth)

/// A no-op `FeedbinClientProtocol` for headless mode: every method performs no
/// network I/O and returns an empty result. Headless boot attaches it, so a sync
/// path that is somehow reached still cannot contact Feedbin. Defence in depth
/// behind the credential skip, which already stops periodic sync.
actor InertFeedbinClient: FeedbinClientProtocol {
  func fetchSubscriptions() async throws -> [FeedbinSubscription] { [] }

  func fetchIcons() async throws -> [FeedbinIcon] { [] }

  func fetchUnreadEntryIDs() async throws -> [Int] { [] }

  func deleteUnreadEntries(_ ids: [Int]) async throws {}

  func verifyCredentials() async throws -> Bool { true }

  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? { nil }

  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}
