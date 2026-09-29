import Foundation

// MARK: - Inert Feedbin client (seam 1, defence in depth)

/// A `FeedbinClientProtocol` for headless mode: no method performs network
/// I/O. Headless boot attaches it, so a sync path that is somehow reached still
/// cannot contact Feedbin. Defence in depth behind the credential skip, which
/// already stops periodic sync.
actor InertFeedbinClient: FeedbinClientProtocol {
  func fetchSubscriptions() async throws -> [FeedbinSubscription] { [] }

  func fetchIcons() async throws -> [FeedbinIcon] { [] }

  func fetchUnreadEntryIDs() async throws -> [Int] { [] }

  // Must throw: a push that succeeds removes its IDs from the `SyncEngine` read
  // queue, and a headless launch shares that queue with the owner's launches.
  func deleteUnreadEntries(_ ids: [Int]) async throws {
    throw URLError(.notConnectedToInternet)
  }

  func verifyCredentials() async throws -> Bool { true }

  func fetchExtractedContent(from extractedContentURL: String) async throws(ExtractedContentFailure) -> String {
    throw .transport(.notConnectedToInternet)
  }

  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}
