import AppKit
import Foundation
import Testing

@testable import Feeder

// MARK: - FaviconStore (issue #148)

/// The store's contract: decode once per feed, dedupe in-flight ids,
/// negative-cache no-favicon feeds, and un-mark a batch on loader failure so
/// a later reload can retry. The loader is closure-injected, so every case
/// runs against a fake with no container and no network.
@MainActor
struct FaviconStoreTests {
  private struct PNGRenderFailure: Error {}

  /// A 1×1 PNG payload rendered in-process — a decodable favicon stand-in
  /// with no fixture file.
  private static func tinyPNG() throws -> Data {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { throw PNGRenderFailure() }
    return png
  }

  @Test
  func loadsAndCachesDecodedImages() async throws {
    let store = FaviconStore()
    let png = try Self.tinyPNG()
    var loadedRequests: [Set<Int>] = []
    await store.ensureLoaded(feedIDs: [1, 2]) { ids in
      loadedRequests.append(ids)
      return [1: png, 2: png]
    }
    #expect(loadedRequests == [[1, 2]])
    #expect(store.image(for: 1) != nil)
    #expect(store.image(for: 2) != nil)
    #expect(store.image(for: nil) == nil)
  }

  @Test
  func attemptedIDsAreNeverHandedToTheLoaderAgain() async throws {
    let store = FaviconStore()
    let png = try Self.tinyPNG()
    var loaderCalls = 0
    await store.ensureLoaded(feedIDs: [1]) { _ in
      loaderCalls += 1
      return [1: png]
    }
    await store.ensureLoaded(feedIDs: [1]) { _ in
      loaderCalls += 1
      return [:]
    }
    #expect(loaderCalls == 1)
  }

  @Test
  func noFaviconFeedsAreNegativeCached() async {
    // A feed the loader returned no data for keeps rendering the initials
    // fallback AND is never refetched; only genuinely new ids reach the
    // loader on the next warm.
    let store = FaviconStore()
    var requested: [Set<Int>] = []
    await store.ensureLoaded(feedIDs: [7]) { ids in
      requested.append(ids)
      return [:]
    }
    await store.ensureLoaded(feedIDs: [7, 8]) { ids in
      requested.append(ids)
      return [:]
    }
    #expect(store.image(for: 7) == nil)
    #expect(requested == [[7], [8]])
  }

  @Test
  func loaderThrowUnmarksTheBatchForRetry() async throws {
    // A store error (or a cancelled reload) is not "this feed has no
    // favicon" — the batch is un-marked so the next reload retries it.
    struct LoaderFailure: Error {}
    let store = FaviconStore()
    let png = try Self.tinyPNG()
    var loaderCalls = 0
    await store.ensureLoaded(feedIDs: [3]) { _ in
      loaderCalls += 1
      throw LoaderFailure()
    }
    #expect(store.image(for: 3) == nil)
    await store.ensureLoaded(feedIDs: [3]) { _ in
      loaderCalls += 1
      return [3: png]
    }
    #expect(loaderCalls == 2)
    #expect(store.image(for: 3) != nil)
  }

  @Test
  func undecodableDataStaysNegativeCached() async {
    // Junk bytes decode to no image; the id still counts as attempted so the
    // store does not hammer the reader with a re-decode per reload.
    let store = FaviconStore()
    var loaderCalls = 0
    await store.ensureLoaded(feedIDs: [9]) { _ in
      loaderCalls += 1
      return [9: Data([0x00])]
    }
    await store.ensureLoaded(feedIDs: [9]) { _ in
      loaderCalls += 1
      return [:]
    }
    #expect(loaderCalls == 1)
    #expect(store.image(for: 9) == nil)
  }
}
