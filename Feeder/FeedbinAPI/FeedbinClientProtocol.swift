import Foundation

/// Minimal protocol covering the `FeedbinClient` surface that `SyncEngine`
/// (and its helper `fetchExtractedContentBatch`) actually invokes. Exists so
/// `SyncEngine` orchestration can be tested with a fake client without
/// stubbing the HTTP layer — the HTTP/decoder/Link-header behaviours are a
/// different test scope owned by `FeedbinClient` directly.
///
/// Keep this protocol intentionally narrow: only add methods here when
/// `SyncEngine` starts calling them. Per `STACK.md § 7` we do
/// not pre-emptively widen interfaces for future use.
protocol FeedbinClientProtocol: Actor {
  func fetchSubscriptions() async throws -> [FeedbinSubscription]
  func fetchIcons() async throws -> [FeedbinIcon]
  func fetchUnreadEntryIDs() async throws -> [Int]
  func deleteUnreadEntries(_ ids: [Int]) async throws
  func verifyCredentials() async throws -> Bool
  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent?

  /// Page-by-page entry fetch as an async sequence. `nonisolated` so callers
  /// can iterate the stream without hopping back onto the actor for every
  /// page — the iteration body inside the stream's task does its own actor
  /// hops as needed. Must stay `nonisolated` here to match the concrete
  /// `FeedbinClient.fetchAllEntryPages` witness.
  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error>
}

extension FeedbinClient: FeedbinClientProtocol {}
