import Foundation
import Testing

@testable import PerfParser

// MARK: - Baseline JSON Codable round-trip

/// Pins the `BaselineDocument` Codable shape so a future field rename or
/// reordering does not silently strip data on `make perf-record-baseline`.
/// The blocker that triggered this work was exactly that: a new
/// `level1_microbench` block lived in the JSON but the Codable type had no
/// matching field, so the first write silently dropped the block. These
/// tests fail fast if the same drift happens again.
@Suite("BaselineDocument Codable round-trip")
struct BaselineCodableTests {
  @Test("Decoding a complete baseline preserves every section")
  func decodesEverySection() throws {
    let json = Self.sampleBaselineJSON
    let doc = try JSONDecoder().decode(BaselineDocument.self, from: Data(json.utf8))
    #expect(doc.schemaVersion == 1)
    #expect(doc.capturedHostCPU == "Apple M3")
    #expect(doc.level1Microbench?.tolerancePct == 20)
    #expect(doc.level1Microbench?.entries.count == 4)
    #expect(doc.level1Microbench?.entries["fetchUnreadCountsSnapshot_micro"]?.medianMs == nil)
    #expect(doc.level2Signposts.frameBudgetMs == 8.3)
    #expect(doc.level4Trace.contentviewBodyGetterPct.max == 9)
    #expect(doc.previousMainHEADRecord?.contentviewBodyGetterPct == 33.8)
  }

  @Test("Round-trip preserves Level 1 entries — no silent strip")
  func roundTripPreservesLevel1Entries() throws {
    let original = try JSONDecoder().decode(
      BaselineDocument.self, from: Data(Self.sampleBaselineJSON.utf8))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(BaselineDocument.self, from: encoded)

    // Level 1 entries survive round-trip with identical key set + values.
    let originalEntries = original.level1Microbench?.entries ?? [:]
    let decodedEntries = decoded.level1Microbench?.entries ?? [:]
    #expect(Set(originalEntries.keys) == Set(decodedEntries.keys))
    for (name, entry) in originalEntries {
      #expect(decodedEntries[name]?.medianMs == entry.medianMs)
    }
    #expect(decoded.level1Microbench?.tolerancePct == original.level1Microbench?.tolerancePct)
    #expect(decoded.level1Microbench?.notes == original.level1Microbench?.notes)
  }

  @Test("Encoded JSON uses the on-disk snake_case keys")
  func encodedJSONUsesSnakeCaseKeys() throws {
    var doc = try JSONDecoder().decode(
      BaselineDocument.self, from: Data(Self.sampleBaselineJSON.utf8))
    // Populate at least one entry's median so the `median_ms` key appears
    // in the encoded output — `JSONEncoder` omits keys whose values are
    // `nil` for `Optional` properties by default.
    doc.level1Microbench?.entries["fetchUnreadCountsSnapshot_micro"] =
      Level1Entry(medianMs: 25.0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(doc)
    let text = String(data: encoded, encoding: .utf8) ?? ""
    #expect(text.contains("\"level1_microbench\""))
    #expect(text.contains("\"tolerance_pct\""))
    #expect(text.contains("\"median_ms\""))
    #expect(text.contains("\"level2_signposts\""))
    #expect(text.contains("\"level4_trace\""))
  }

  @Test("Writing micro-benchmark medians merges into existing entries")
  func writeMicroBenchmarkMediansMergesEntries() throws {
    let tmp = try Self.makeTempBaselineFile()
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let initial = try loadBaseline(at: tmp)
    let medians = MicroBenchmarkMedians(medianMsByName: [
      "fetchUnreadCountsSnapshot_micro": 12.5,
      "parseHTMLToBlocks_micro": 2.3,
      // A new benchmark name not in the seed should be added.
      "newlyAdded_micro": 99.9,
    ])
    try Baseline.writeMicroBenchmarkMedians(medians, into: tmp, current: initial)

    let reloaded = try loadBaseline(at: tmp)
    let entries = reloaded.level1Microbench?.entries ?? [:]
    #expect(entries["fetchUnreadCountsSnapshot_micro"]?.medianMs == 12.5)
    #expect(entries["parseHTMLToBlocks_micro"]?.medianMs == 2.3)
    #expect(entries["newlyAdded_micro"]?.medianMs == 99.9)
    // Untouched entries keep their existing slots — no silent strip.
    #expect(entries["groupEntriesByDay_micro"] != nil)
    #expect(reloaded.level1Microbench?.capturedOn != nil)
  }

  // MARK: - Fixtures

  /// Mirror of `Tests/PerfBaselines/baseline-current.json` at the time this
  /// test was authored. Kept inline so a renamed real baseline file cannot
  /// silently invalidate the round-trip guarantee.
  static let sampleBaselineJSON: String = """
    {
      "captured_host_cpu" : "Apple M3",
      "captured_on" : "2026-05-25T18:02:58Z",
      "level1_microbench" : {
        "captured_on" : null,
        "entries" : {
          "fetchEntrySections_category_micro" : { "median_ms" : null },
          "fetchUnreadCountsSnapshot_micro" : { "median_ms" : null },
          "groupEntriesByDay_micro" : { "median_ms" : null },
          "parseHTMLToBlocks_micro" : { "median_ms" : null }
        },
        "notes" : "test fixture",
        "tolerance_pct" : 20
      },
      "level2_signposts" : {
        "frame_budget_ms" : 8.3,
        "tolerance_pct" : 20
      },
      "level4_trace" : {
        "contentview_body_getter_pct" : { "captured" : 0, "max" : 9 },
        "contentview_unread_entries_getter_pct" : { "captured" : 0, "max" : 0.1 },
        "full_hangs_ge_500ms_count" : { "captured" : 1, "max" : 1 },
        "microhangs_ge_250ms_count" : { "captured" : 1, "max" : 5 }
      },
      "previous_main_head_record" : {
        "captured_for" : "diagnosis baseline pre-perf-fix",
        "contentview_body_getter_pct" : 33.8,
        "contentview_unread_entries_getter_pct" : 28.9,
        "full_hangs_ge_500ms_count" : 1,
        "microhangs_ge_250ms_count" : 43,
        "session_seconds" : 55
      },
      "schema_version" : 1
    }
    """

  static func makeTempBaselineFile() throws -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("perfparser-baseline-\(UUID().uuidString).json")
    try Data(sampleBaselineJSON.utf8).write(to: url)
    return url.path
  }
}
