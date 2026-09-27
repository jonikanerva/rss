import Foundation
import SwiftData

@testable import Feeder

// MARK: - Fake Feedbin client

/// In-memory `FeedbinClientProtocol` for the sync tests. It models only the
/// surface those tests exercise; a method the engine calls but no test asserts
/// on returns a safe default and still behaves like the real client, so a sync
/// runs end to end. The methods that the tests assert on record their calls, so
/// a test introspects the orchestration without reaching into private state.
actor FakeFeedbinClient: FeedbinClientProtocol {
  // MARK: Configurable responses

  var subscriptionsResponse: [FeedbinSubscription] = []
  var unreadIDsResponse: [Int] = []
  var entryPagesResponse: [FeedbinEntriesPage] = []
  var verifyResult: Result<Bool, any Error> = .success(true)

  // MARK: Configurable errors (non-nil → thrown instead of returning)

  var subscriptionsError: Error?
  var extractedContentError: Error?
  /// Thrown after the call enters `deleteUnreadEntriesCallLog`, so the log
  /// also holds the batch of a failed push.
  var deleteUnreadEntriesError: Error?

  // MARK: Gates

  /// While set, `verifyCredentials()` waits until the gate opens.
  private var verifyGate: AsyncGate?
  /// While set, `deleteUnreadEntries` logs the call and then waits until the
  /// gate opens.
  private var deleteUnreadEntriesGate: AsyncGate?
  /// While set, the page stream bumps `fetchEntryPagesCallCount` and then waits
  /// until the gate opens before it yields a page.
  private var entryPagesGate: AsyncGate?
  /// While set, the page stream waits until the gate opens before it yields
  /// each page after the first, so the stream stays open after the first page.
  private var laterEntryPagesGate: AsyncGate?

  // MARK: Call logs

  /// Each entry is the ID batch passed to one `deleteUnreadEntries` call.
  var deleteUnreadEntriesCallLog: [[Int]] = []
  /// Recorded URLs `fetchExtractedContent(from:)` was called with.
  var extractedContentCallLog: [String] = []
  /// How many times the page stream was entered. The stream bumps it in the
  /// actor hop that reads its configuration, before it yields a page, so a
  /// race-guard test gates on it.
  var fetchEntryPagesCallCount: Int = 0
  /// Bumped when `verifyCredentials()` is entered, before any gate wait.
  var verifyCallCount: Int = 0

  // MARK: - FeedbinClientProtocol

  func fetchSubscriptions() async throws -> [FeedbinSubscription] {
    if let error = subscriptionsError { throw error }
    return subscriptionsResponse
  }

  func fetchIcons() async throws -> [FeedbinIcon] {
    // No test asserts on icons, so return an empty list and let the sync finish
    // its icon pass.
    []
  }

  func fetchUnreadEntryIDs() async throws -> [Int] {
    unreadIDsResponse
  }

  func deleteUnreadEntries(_ ids: [Int]) async throws {
    deleteUnreadEntriesCallLog.append(ids)
    if let deleteUnreadEntriesGate { await deleteUnreadEntriesGate.wait() }
    if let deleteUnreadEntriesError { throw deleteUnreadEntriesError }
  }

  func verifyCredentials() async throws -> Bool {
    verifyCallCount += 1
    if let verifyGate { await verifyGate.wait() }
    return try verifyResult.get()
  }

  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? {
    extractedContentCallLog.append(extractedContentURL)
    if let error = extractedContentError { throw error }
    return nil
  }

  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    // One snapshot of the configuration, taken in a single hop, so the stream's
    // task holds no actor across a page yield and never captures `self`
    // (`STACK.md § 7`).
    let snapshotTask = Task { await self.snapshotEntryPagesState() }
    return AsyncThrowingStream { continuation in
      let task = Task {
        let snapshot = await snapshotTask.value
        if let gate = snapshot.gate { await gate.wait() }
        for (index, page) in snapshot.pages.enumerated() {
          if Task.isCancelled { break }
          if index > 0, let laterGate = snapshot.laterGate { await laterGate.wait() }
          continuation.yield(page)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Configuration setters (actor-isolated mutators)

  func setSubscriptionsResponse(_ value: [FeedbinSubscription]) { subscriptionsResponse = value }
  func setUnreadIDsResponse(_ value: [Int]) { unreadIDsResponse = value }
  func setEntryPagesResponse(_ value: [FeedbinEntriesPage]) { entryPagesResponse = value }
  func setSubscriptionsError(_ value: Error?) { subscriptionsError = value }
  func setVerifyResult(_ value: Result<Bool, any Error>) { verifyResult = value }
  func holdVerification(until gate: AsyncGate) { verifyGate = gate }
  func setDeleteUnreadEntriesError(_ value: Error?) { deleteUnreadEntriesError = value }
  func holdDeleteUnreadEntries(until gate: AsyncGate) { deleteUnreadEntriesGate = gate }
  func holdEntryPages(until gate: AsyncGate) { entryPagesGate = gate }
  func holdLaterEntryPages(until gate: AsyncGate) { laterEntryPagesGate = gate }

  // MARK: - Internal

  /// Read the snapshot and bump the call counter in one actor hop, so a moved
  /// counter means that the stream has read its configuration, gates included.
  /// The engine's own flag is no such signal: it flips before any client call.
  private func snapshotEntryPagesState() -> (
    pages: [FeedbinEntriesPage], gate: AsyncGate?, laterGate: AsyncGate?
  ) {
    fetchEntryPagesCallCount += 1
    return (entryPagesResponse, entryPagesGate, laterEntryPagesGate)
  }
}

// MARK: - Test-only DataWriter introspection

extension DataWriter {
  /// Count the entry rows in the in-memory store, so a test asserts the engine
  /// persisted entries without crossing actor boundaries by hand.
  func entryCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<Entry>())
  }
}
