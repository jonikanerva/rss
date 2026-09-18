import Foundation
import SwiftData

@testable import Feeder

// MARK: - Fake Feedbin client

/// In-memory `FeedbinClientProtocol` for the sync tests. It models only the
/// surface those tests exercise; a method the engine calls but no test asserts
/// on returns a safe default and still behaves like the real client, so a sync
/// runs end to end. Every method records its invocations, so a test introspects
/// the orchestration without reaching into private state.
actor FakeFeedbinClient: FeedbinClientProtocol {
  // MARK: Configurable responses

  var subscriptionsResponse: [FeedbinSubscription] = []
  var unreadIDsResponse: [Int] = []
  var entryPagesResponse: [FeedbinEntriesPage] = []

  // MARK: Configurable errors (non-nil → thrown instead of returning)

  var subscriptionsError: Error?
  var extractedContentError: Error?

  // MARK: Timing knobs

  /// Sleep inserted before the page yielding begins, so a race-guard test keeps
  /// the primary sync in flight while a second operation tries to start. It
  /// sits after the call-count bump, so that counter signals the stream started.
  var entryPagesInitialDelay: Duration = .zero

  /// Sleep inserted between page yields, which keeps the stream open after the
  /// first page is consumed. A test then observes the engine's live fetch total
  /// while the sync is still running.
  var entryPagesInterPageDelay: Duration = .zero

  // MARK: Call logs

  /// Each entry is the ID batch passed to one `deleteUnreadEntries` call.
  var deleteUnreadEntriesCallLog: [[Int]] = []
  /// Recorded URLs `fetchExtractedContent(from:)` was called with.
  var extractedContentCallLog: [String] = []
  /// How many times the page stream was entered. Bumped synchronously at the
  /// start of the stream's body, so a race-guard test gates on it.
  var fetchEntryPagesCallCount: Int = 0

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
  }

  func verifyCredentials() async throws -> Bool {
    // No test exercises this. Return `true`, mirroring the production contract.
    true
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
        if snapshot.delay > .zero {
          try? await Task.sleep(for: snapshot.delay)
        }
        for (index, page) in snapshot.pages.enumerated() {
          if Task.isCancelled { break }
          if index > 0 && snapshot.interPageDelay > .zero {
            try? await Task.sleep(for: snapshot.interPageDelay)
          }
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
  func setEntryPagesInitialDelay(_ value: Duration) { entryPagesInitialDelay = value }
  func setEntryPagesInterPageDelay(_ value: Duration) { entryPagesInterPageDelay = value }

  // MARK: - Internal

  /// Read the snapshot and bump the call counter in one actor hop, so the
  /// counter is a reliable "the stream body has started" signal. The engine's
  /// own flag is not: it flips before any client call.
  private func snapshotEntryPagesState() -> (
    pages: [FeedbinEntriesPage], delay: Duration, interPageDelay: Duration
  ) {
    fetchEntryPagesCallCount += 1
    return (entryPagesResponse, entryPagesInitialDelay, entryPagesInterPageDelay)
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
