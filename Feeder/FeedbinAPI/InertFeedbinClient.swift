import Foundation

// MARK: - Inert Feedbin client (seam 1, defence in depth)

/// A no-op `FeedbinClientProtocol` used only in headless mode (#141). Every
/// method performs no network I/O and returns an empty result. Headless boot
/// attaches it to `SyncEngine` so that even if a sync path were somehow reached,
/// it can never contact Feedbin — belt-and-suspenders behind the credential-skip
/// that already stops periodic sync from starting on an automated launch.
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
