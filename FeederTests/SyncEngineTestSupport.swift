import Foundation
import SwiftData

@testable import Feeder

// MARK: - Fake Feedbin client

/// In-memory `FeedbinClientProtocol` implementation for `SyncEngine` tests.
/// Each method either replays a pre-configured response, throws a
/// pre-configured error, or — for entry pages — yields the configured pages
/// through an `AsyncThrowingStream`. Method invocations are recorded so
/// tests can assert orchestration behaviour (e.g. mark-read flush).
///
/// Lives in test target only; production code never sees this type.
actor FakeFeedbinClient: FeedbinClientProtocol {
  // MARK: Configurable responses

  var subscriptionsResponse: [FeedbinSubscription] = []
  var iconsResponse: [FeedbinIcon] = []
  var unreadIDsResponse: [Int] = []
  var entryPagesResponse: [FeedbinEntriesPage] = []
  var verifyCredentialsResponse: Bool = true
  var extractedContentResponse: FeedbinExtractedContent?

  // MARK: Configurable errors (any non-nil error is thrown instead of returning)

  var subscriptionsError: Error?
  var iconsError: Error?
  var unreadIDsError: Error?
  var entryPagesError: Error?
  var verifyCredentialsError: Error?
  var deleteUnreadEntriesError: Error?

  // MARK: Timing knobs

  /// Sleep inserted before each entry page is yielded. Lets race-guard tests
  /// keep the primary sync in-flight while a second operation tries to start.
  var entryPagesPerPageDelay: Duration = .zero

  // MARK: Call logs

  /// Each entry is the ID batch passed to a single `deleteUnreadEntries` call.
  var deleteUnreadEntriesCallLog: [[Int]] = []
  var fetchSubscriptionsCallCount: Int = 0
  var fetchEntryPagesCallCount: Int = 0

  // MARK: - FeedbinClientProtocol

  func fetchSubscriptions() async throws -> [FeedbinSubscription] {
    fetchSubscriptionsCallCount += 1
    if let error = subscriptionsError { throw error }
    return subscriptionsResponse
  }

  func fetchIcons() async throws -> [FeedbinIcon] {
    if let error = iconsError { throw error }
    return iconsResponse
  }

  func fetchUnreadEntryIDs() async throws -> [Int] {
    if let error = unreadIDsError { throw error }
    return unreadIDsResponse
  }

  func deleteUnreadEntries(_ ids: [Int]) async throws {
    if let error = deleteUnreadEntriesError { throw error }
    deleteUnreadEntriesCallLog.append(ids)
  }

  func verifyCredentials() async throws -> Bool {
    if let error = verifyCredentialsError { throw error }
    return verifyCredentialsResponse
  }

  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? {
    extractedContentResponse
  }

  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    AsyncThrowingStream { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish()
          return
        }
        await self.bumpEntryPagesCallCount()
        if let error = await self.entryPagesError {
          continuation.finish(throwing: error)
          return
        }
        let pages = await self.entryPagesResponse
        let delay = await self.entryPagesPerPageDelay
        for page in pages {
          if delay > .zero {
            try? await Task.sleep(for: delay)
          }
          if Task.isCancelled { break }
          continuation.yield(page)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Configuration helpers (actor-isolated mutators usable from sync tests)

  func setSubscriptionsResponse(_ value: [FeedbinSubscription]) { subscriptionsResponse = value }
  func setIconsResponse(_ value: [FeedbinIcon]) { iconsResponse = value }
  func setUnreadIDsResponse(_ value: [Int]) { unreadIDsResponse = value }
  func setEntryPagesResponse(_ value: [FeedbinEntriesPage]) { entryPagesResponse = value }
  func setSubscriptionsError(_ value: Error?) { subscriptionsError = value }
  func setEntryPagesPerPageDelay(_ value: Duration) { entryPagesPerPageDelay = value }

  private func bumpEntryPagesCallCount() {
    fetchEntryPagesCallCount += 1
  }
}

// MARK: - Fixture builders

enum SyncEngineFixtures {
  /// Build a `FeedbinSubscription` via the production JSON decoder so the test
  /// exercises the same field-name conventions as the real API path.
  static func subscription(
    id: Int = 1,
    feedId: Int = 100,
    title: String = "Test Feed",
    feedUrl: String = "https://example.com/feed.xml",
    siteUrl: String = "https://www.example.com",
    createdAt: String = "2026-01-01T00:00:00.000000Z"
  ) throws -> FeedbinSubscription {
    let json: [String: Any] = [
      "id": id,
      "feed_id": feedId,
      "title": title,
      "feed_url": feedUrl,
      "site_url": siteUrl,
      "created_at": createdAt,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinSubscription.self, from: data)
  }

  /// Build a `FeedbinEntry` via the production JSON decoder.
  static func entry(
    id: Int = 1001,
    feedId: Int = 100,
    title: String = "Test Article",
    content: String = "<p>Body</p>",
    url: String = "https://example.com/article",
    published: String = "2026-05-01T12:00:00.000000Z"
  ) throws -> FeedbinEntry {
    let json: [String: Any] = [
      "id": id,
      "feed_id": feedId,
      "title": title,
      "content": content,
      "url": url,
      "published": published,
      "created_at": published,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinEntry.self, from: data)
  }

  static func entriesPage(
    _ entries: [FeedbinEntry],
    hasNextPage: Bool = false,
    totalCount: Int? = nil
  ) -> FeedbinEntriesPage {
    FeedbinEntriesPage(entries: entries, hasNextPage: hasNextPage, totalCount: totalCount ?? entries.count)
  }
}

// MARK: - Test-only DataWriter introspection

extension DataWriter {
  /// Count `Entry` rows in the in-memory store. Test-only convenience so
  /// `SyncEngineTests` can assert that the orchestration actually persisted
  /// entries without crossing actor boundaries by hand.
  func entryCount() throws -> Int {
    try modelContext.fetchCount(FetchDescriptor<Entry>())
  }
}
