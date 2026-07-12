import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - Article-list paging math (issue #151)

/// Pure pins for the paging arithmetic driving the row cap + lazy-append.
struct EntryListPagingTests {
  // MARK: - hasMorePages

  @Test
  func fullWindowMeansMore() {
    #expect(hasMorePages(fetchedCount: 100, limit: 100))
  }

  @Test
  func shortWindowMeansNoMore() {
    #expect(!hasMorePages(fetchedCount: 99, limit: 100))
    #expect(!hasMorePages(fetchedCount: 0, limit: 100))
  }

  @Test
  func overfullWindowStillMeansMore() {
    // Pin coverage can fetch past the requested limit before the caller
    // adopts the effective limit; treat it as "window filled".
    #expect(hasMorePages(fetchedCount: 250, limit: 100))
  }

  // MARK: - nextRowLimit

  @Test
  func growthAddsOneStep() {
    #expect(nextRowLimit(current: 100, growthStep: 200) == 300)
    #expect(nextRowLimit(current: 300, growthStep: 200) == 500)
  }

  // MARK: - appendTriggerIndex

  @Test
  func triggerSitsMarginRowsBeforeTheEnd() {
    #expect(appendTriggerIndex(fetchedCount: 100, margin: 20) == 80)
    #expect(appendTriggerIndex(fetchedCount: 300, margin: 20) == 280)
  }

  @Test
  func triggerClampsToFirstRowForTinyWindows() {
    #expect(appendTriggerIndex(fetchedCount: 10, margin: 20) == 0)
  }

  @Test
  func triggerClampsInsideTheWindowForZeroMargin() {
    #expect(appendTriggerIndex(fetchedCount: 100, margin: 0) == 99)
  }

  @Test
  func emptyWindowHasNoTrigger() {
    #expect(appendTriggerIndex(fetchedCount: 0, margin: 20) == nil)
  }

  // MARK: - effectiveRowLimit

  @Test
  func pinBeyondTheWindowGrowsTheLimit() {
    #expect(effectiveRowLimit(requested: 100, pinPosition: 180) == 180)
  }

  @Test
  func pinInsideTheWindowKeepsTheRequest() {
    #expect(effectiveRowLimit(requested: 100, pinPosition: 40) == 100)
  }
}

// MARK: - isPrefixExtension (needs minted PersistentIdentifiers)

@MainActor
struct PrefixExtensionTests {
  /// Mint distinct `PersistentIdentifier`s (no public initializer) from a
  /// throwaway in-memory context; the math under test reads only the values.
  private static func mintIDs(count: Int) throws -> [PersistentIdentifier] {
    let context = ModelContext(try DataWriterTestSupport.makeInMemoryContainer())
    return (0..<count).map { offset in
      let entry = Entry(
        feedbinEntryID: 7000 + offset, title: nil, author: nil,
        url: "https://example.com/\(offset)", content: nil, summary: nil,
        extractedContentURL: nil, publishedAt: .now, createdAt: .now)
      context.insert(entry)
      return entry.persistentModelID
    }
  }

  @Test
  func tailGrowthIsAPrefixExtension() throws {
    let ids = try Self.mintIDs(count: 4)
    #expect(isPrefixExtension(previous: Array(ids[0..<2]), new: ids))
  }

  @Test
  func emptyPreviousIsNotAnExtension() throws {
    // A structural first fetch must keep its normal anchor logic.
    let ids = try Self.mintIDs(count: 2)
    #expect(!isPrefixExtension(previous: [], new: ids))
  }

  @Test
  func identicalIDsAreNotAnExtension() throws {
    let ids = try Self.mintIDs(count: 3)
    #expect(!isPrefixExtension(previous: ids, new: ids))
  }

  @Test
  func topInsertIsNotAnExtension() throws {
    // A sync page landing new rows ABOVE the window changes the prefix —
    // the anchor-restore logic must run (option (a) top-stability).
    let ids = try Self.mintIDs(count: 4)
    #expect(!isPrefixExtension(previous: Array(ids[1..<3]), new: ids))
  }

  @Test
  func shrunkResultIsNotAnExtension() throws {
    let ids = try Self.mintIDs(count: 3)
    #expect(!isPrefixExtension(previous: ids, new: Array(ids[0..<2])))
  }
}
