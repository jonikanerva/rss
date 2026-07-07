import Foundation
import SwiftData

@testable import Feeder

// MARK: - Fake Feedbin client

/// In-memory `FeedbinClientProtocol` implementation for `SyncEngine` tests.
///
/// Only the surface `SyncEngineTests` actually exercises is modeled here.
/// Methods the engine calls but the tests don't assert on (icons,
/// extracted content, credentials) return safe defaults — they still need
/// to behave like the real client so `sync()` can run end-to-end.
///
/// All methods record their invocations in their own `*CallLog`, mirroring
/// the same pattern, so any test (current or future) can introspect the
/// orchestration without reaching into private state.
///
/// Lives in the test target only; production code never sees this type.
actor FakeFeedbinClient: FeedbinClientProtocol {
  // MARK: Configurable responses

  var subscriptionsResponse: [FeedbinSubscription] = []
  var unreadIDsResponse: [Int] = []
  var entryPagesResponse: [FeedbinEntriesPage] = []

  // MARK: Configurable errors (non-nil → thrown instead of returning)

  var subscriptionsError: Error?
  var extractedContentError: Error?

  // MARK: Timing knobs

  /// Sleep inserted **before** entry-page yielding begins. Lets race-guard
  /// tests keep the primary sync in-flight while a second operation tries
  /// to start. The delay sits between the `bumpEntryPagesCallCount` and
  /// the first page yield, so tests can gate on `fetchEntryPagesCallCount`
  /// to know the stream has been entered.
  var entryPagesInitialDelay: Duration = .zero

  /// Sleep inserted **between** page yields (before every page after the
  /// first). Keeps the entry-page stream open after page 1 has been consumed,
  /// so a test can observe `SyncEngine`'s live `totalToFetch` (set un-throttled
  /// from each page's total the moment a page lands, SyncEngine.swift) while
  /// `isSyncing` is still true — the regression pin for issue #124's "B is
  /// already live" claim.
  var entryPagesInterPageDelay: Duration = .zero

  // MARK: Call logs

  /// Each entry is the ID batch passed to one `deleteUnreadEntries` call.
  var deleteUnreadEntriesCallLog: [[Int]] = []
  /// Recorded URLs `fetchExtractedContent(from:)` was called with.
  var extractedContentCallLog: [String] = []
  /// Number of times `fetchAllEntryPages` was invoked. Bumped synchronously
  /// at the start of the stream's body so race-guard tests can gate on it.
  var fetchEntryPagesCallCount: Int = 0

  // MARK: - FeedbinClientProtocol

  func fetchSubscriptions() async throws -> [FeedbinSubscription] {
    if let error = subscriptionsError { throw error }
    return subscriptionsResponse
  }

  func fetchIcons() async throws -> [FeedbinIcon] {
    // Icons aren't asserted by any current test — return an empty list so
    // `SyncEngine.sync()` can complete its icon pass.
    []
  }

  func fetchUnreadEntryIDs() async throws -> [Int] {
    unreadIDsResponse
  }

  func deleteUnreadEntries(_ ids: [Int]) async throws {
    deleteUnreadEntriesCallLog.append(ids)
  }

  func verifyCredentials() async throws -> Bool {
    // Not exercised by any current test. Return `true` so the production
    // contract ("valid creds → true") is mirrored.
    true
  }

  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? {
    extractedContentCallLog.append(extractedContentURL)
    if let error = extractedContentError { throw error }
    return nil
  }

  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    // Snapshot of the actor's response/delay configuration captured in one
    // hop. Doing it once up-front means the stream's task does not need to
    // hold the actor across each page yield — and crucially the stream
    // task does **not** capture `self`, sidestepping the `[weak self]`
    // prohibition in `STACK.md § 7`.
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

  /// Read the page-stream snapshot **and** bump the call counter in one
  /// actor hop. Done together so race-guard tests can use the counter as a
  /// reliable "the stream's body has started" signal without depending on
  /// `SyncEngine`'s `isSyncing` flag, which flips before any client call.
  private func snapshotEntryPagesState() -> (
    pages: [FeedbinEntriesPage], delay: Duration, interPageDelay: Duration
  ) {
    fetchEntryPagesCallCount += 1
    return (entryPagesResponse, entryPagesInitialDelay, entryPagesInterPageDelay)
  }
}

// MARK: - Test-only DataWriter introspection

extension DataWriter {
  /// Count `Entry` rows in the in-memory store. Test-only convenience so
  /// `SyncEngineTests` can assert the engine actually persisted entries
  /// without crossing actor boundaries by hand.
  func entryCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<Entry>())
  }
}
