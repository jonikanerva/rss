import AppKit
import Observation

// MARK: - Favicon Store

/// MainActor-owned favicon cache for the article list: one decoded `NSImage`
/// per feed, keyed by `feedbinFeedID` (issue #148).
///
/// **Why MainActor:** `NSImage` is not `Sendable`, and every consumer is a
/// SwiftUI row render — keeping the dictionary MainActor-isolated makes the
/// render-path lookup a plain dictionary read with no hop and no locking. The
/// decode itself runs here ONCE per feed (in `ensureLoaded`), never in `body`
/// — the per-row render-time `NSImage(data:)` this replaces was the § 7
/// "expensive work in body" cost the issue removes.
///
/// **Why no eviction / disk / network:** the cache is feed-count-sized (one
/// small image per subscription — tens, not thousands), lives for the app's
/// lifetime, and its source of truth is the store's `faviconData` column,
/// which sync maintains. Evicting would only re-pay the decode.
@MainActor
@Observable
final class FaviconStore {
  /// Decoded favicon per `feedbinFeedID`. `body` reads via `image(for:)`.
  private(set) var images: [Int: NSImage] = [:]
  /// In-flight dedupe AND negative cache: ids already handed to a loader.
  /// A feed the loader returned no data for stays here — it has no favicon
  /// and is never refetched; its rows render the initials fallback.
  private var attempted: Set<Int> = []

  /// Render-path lookup — a synchronous dictionary read, safe in `body`.
  func image(for feedbinFeedID: Int?) -> NSImage? {
    guard let feedbinFeedID else { return nil }
    return images[feedbinFeedID]
  }

  /// Warm the cache for the given feeds. `load` is closure-injected (the
  /// production loader is `DataReader.fetchFaviconData`; tests inject a fake)
  /// and receives ONLY the not-yet-attempted ids. Ids absent from the
  /// loader's result are negative-cached via `attempted`. On a loader THROW
  /// the batch is un-marked so a later reload can retry — a store error (or
  /// a cancelled reload task) is not "this feed has no favicon".
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
