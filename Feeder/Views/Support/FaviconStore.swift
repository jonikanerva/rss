import AppKit
import Observation

// MARK: - Favicon Store

/// MainActor-owned favicon cache for the article list: one decoded `NSImage`
/// per feed.
///
/// MainActor, because `NSImage` is not `Sendable` and every consumer is a row
/// render, so the render-path lookup is a plain dictionary read with no hop.
/// The decode runs once per feed in `ensureLoaded`, never in `body`
/// (`STACK.md § 7`).
///
/// No eviction, no disk, no network: the cache holds one small image per
/// subscription, lives for the app's lifetime, and takes its source of truth
/// from the store column that sync maintains.
@MainActor
@Observable
final class FaviconStore {
  /// Decoded favicon per `feedbinFeedID`. `body` reads via `image(for:)`.
  private(set) var images: [Int: NSImage] = [:]
  /// In-flight dedupe and negative cache: ids already handed to a loader. A
  /// feed the loader returned no data for stays here, is never refetched, and
  /// renders the initials fallback.
  private var attempted: Set<Int> = []

  /// Render-path lookup — a synchronous dictionary read, safe in `body`.
  func image(for feedbinFeedID: Int?) -> NSImage? {
    guard let feedbinFeedID else { return nil }
    return images[feedbinFeedID]
  }

  /// Warm the cache for the given feeds. `load` receives only the
  /// not-yet-attempted ids, and an id missing from its result is
  /// negative-cached. A throwing loader un-marks the batch so a later reload
  /// retries: a store error is not "this feed has no favicon".
  func ensureLoaded(
    feedIDs: Set<Int>, load: (Set<Int>) async throws -> [Int: Data]
  ) async {
    let missing = feedIDs.subtracting(attempted)
    guard !missing.isEmpty else { return }
    attempted.formUnion(missing)
    do {
      let faviconData = try await load(missing)
      for (id, data) in faviconData {
        if let image = NSImage(data: data) { images[id] = image }
      }
    } catch {
      attempted.subtract(missing)
    }
  }
}
