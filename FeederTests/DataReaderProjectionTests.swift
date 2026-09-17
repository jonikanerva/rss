import Foundation
import Testing

@testable import Feeder

/// Row projection contract (issue #170): `EntryRowDTO.displayDomain` is `nil`
/// whenever the entry has no domain. `extractDomain` stores "" for a URL
/// without a host; `DataReader.projectEntryRow` maps that to `nil`, so the
/// row reserves its domain line with the placeholder in every no-domain case
/// and never renders an empty `Text` (14 pt at every size). Runs against the
/// production writer + reader pair on one shared in-memory container;
/// concurrent-coordinator pressure is capped by the serial unit-target run
/// (`STACK.md § 14`), `.serialized` only orders tests within the suite.
@Suite("DataReader row projection", .serialized)
struct DataReaderProjectionTests {
  /// Seed one feed with `siteUrl` and one classified `tech` entry through the
  /// production write path, then return the projected row.
  private func projectedRow(siteUrl: String) async throws -> EntryRowDTO {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    try await writer.syncFeeds([FeedbinFixtures.subscription(siteUrl: siteUrl)])
    try await writer.addCategory(
      label: "tech", displayName: "Tech", description: "Tech news", sortOrder: 0)
    _ = try await writer.persistEntries([FeedbinFixtures.entry(id: 1)], unreadIDs: [1])
    try await writer.applyClassification(
      entryID: 1, result: ClassificationResult(entryID: 1, categoryLabel: "tech", confidence: 0.9))
    let result = try await reader.fetchEntrySections(
      category: "tech", folder: nil, showRead: false,
      cutoffDate: .distantPast, pinnedFeedbinEntryID: nil, window: .firstPage(limit: 10))
    return try #require(result.sections.first?.rows.first)
  }

  @Test("a feed whose site URL has no host projects a nil domain, not an empty string")
  func hostlessSiteURLProjectsNilDomain() async throws {
    // `URL(string: "about:blank")?.host()` is nil, so `extractDomain` stores "".
    let row = try await projectedRow(siteUrl: "about:blank")
    #expect(row.displayDomain == nil)
  }

  @Test("a feed with a host keeps its display domain")
  func siteURLWithHostKeepsDomain() async throws {
    let row = try await projectedRow(siteUrl: "https://www.example.com")
    #expect(row.displayDomain == "example.com")
  }
}
