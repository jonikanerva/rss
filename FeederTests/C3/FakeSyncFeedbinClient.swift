import Foundation

@testable import Feeder

// MARK: - C3 fake sync client (issue #138)

/// A `FeedbinClientProtocol` fake that replays a large paged first-sync with an
/// INJECTED per-page network latency (`Tnet`), so the C3 measurement can drive
/// the REAL `SyncEngine`-shaped consume path (unbounded `AsyncThrowingStream`
/// prefetch) against a real `DataWriter` — the exact buffering behaviour whose
/// coordinator saturation issue #138 is measuring.
///
/// The pages are pre-built once and handed in, so yielding is allocation-free
/// and the only per-page delay is the injected `Tnet`. All entry IDs sit far
/// above `seedPerfTestData`'s fixture range so the burst never collides with
/// the seeded read fixture.
///
/// Only `fetchAllEntryPages` (stream arms) and `fetchOnePage` (the sequential
/// 3a arm) carry behaviour; the rest are inert stubs — `SyncEngine`'s entry
/// path is the only surface this fake needs (`STACK.md § 13`, narrow protocol).
actor FakeSyncFeedbinClient: FeedbinClientProtocol {
  /// Pre-built pages, in order. `Sendable` (`FeedbinEntriesPage` is), so the
  /// nonisolated stream closure captures them directly.
  private nonisolated let pages: [FeedbinEntriesPage]
  /// Injected per-page network GET latency. A conservative LOWER-BOUND Tnet
  /// (transfer-only floor) is worst-case-safe for the benign-here-benign-
  /// everywhere guard — see the measurement suite's Tnet documentation.
  private nonisolated let tnet: Duration

  init(pages: [FeedbinEntriesPage], tnet: Duration) {
    self.pages = pages
    self.tnet = tnet
  }

  var pageCount: Int { pages.count }

  /// The unbounded prefetch path (BURST / YIELD / 3b arms). Default
  /// `AsyncThrowingStream` buffering (`.unbounded`) → `yield` never suspends →
  /// pages prefetch ahead of the consumer, collapsing the persist cadence. This
  /// is the production mechanism under test, reproduced faithfully.
  nonisolated func fetchAllEntryPages(since: Date?) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    let pages = self.pages
    let tnet = self.tnet
    return AsyncThrowingStream { continuation in
      let task = Task {
        for page in pages {
          if Task.isCancelled { break }
          try? await Task.sleep(for: tnet)
          continuation.yield(page)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// One page after `Tnet` — the sequential (3a) arm awaits this inline so the
  /// network gap sits BETWEEN persists (no prefetch buffer).
  nonisolated func fetchOnePage(index: Int) async -> FeedbinEntriesPage? {
    guard index >= 0, index < pages.count else { return nil }
    try? await Task.sleep(for: tnet)
    return pages[index]
  }

  // MARK: - Inert stubs (unused by the entry-sync path under measurement)

  func fetchSubscriptions() async throws -> [FeedbinSubscription] { [] }
  func fetchIcons() async throws -> [FeedbinIcon] { [] }
  func fetchUnreadEntryIDs() async throws -> [Int] { [] }
  func deleteUnreadEntries(_ ids: [Int]) async throws {}
  func verifyCredentials() async throws -> Bool { true }
  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? { nil }
}
