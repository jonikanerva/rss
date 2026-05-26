import Foundation
import Testing

@testable import PerfParser

// MARK: - Level 1 extractor + comparator

@Suite("MicroBenchmarkMetricsExtractor parsing")
struct MicroBenchmarkExtractorParsingTests {
  @Test("Parses wall-clock medians for the four hot-path benchmarks")
  func parsesFourHotPathBenchmarks() throws {
    let medians = try MicroBenchmarkMetricsExtractor.parseTestsJSON(
      Data(Self.fixtureTestsJSON.utf8))
    // 0.025s -> 25 ms, etc.
    #expect(medians.medianMsByName["fetchUnreadCountsSnapshot_micro"] == 25.0)
    #expect(medians.medianMsByName["fetchEntrySections_category_micro"] == 14.0)
    #expect(medians.medianMsByName["parseHTMLToBlocks_micro"] == 1.5)
    #expect(medians.medianMsByName["groupEntriesByDay_micro"] == 3.0)
  }

  @Test("Ignores test nodes that are not under MicroBenchmarkTests")
  func ignoresUnrelatedTestNodes() throws {
    let medians = try MicroBenchmarkMetricsExtractor.parseTestsJSON(
      Data(Self.fixtureTestsJSON.utf8))
    #expect(medians.medianMsByName["sidebar_click_signpost"] == nil)
    #expect(medians.medianMsByName["test_sidebar_click_signpost"] == nil)
  }

  @Test("Ignores non-wall-clock metrics")
  func ignoresOtherMetrics() {
    #expect(
      MicroBenchmarkMetricsExtractor.isWallClockMetric(
        identifier: "com.apple.XCTPerformanceMetric_WallClockTime") == true)
    #expect(
      MicroBenchmarkMetricsExtractor.isWallClockMetric(
        identifier: "com.apple.dt.XCTMetric_Clock.time.monotonic") == true)
    #expect(
      MicroBenchmarkMetricsExtractor.isWallClockMetric(
        identifier: "Clock Monotonic Time") == true)
    #expect(
      MicroBenchmarkMetricsExtractor.isWallClockMetric(
        identifier: "com.apple.dt.XCTMetric_Memory.peak_physical") == false)
    #expect(
      MicroBenchmarkMetricsExtractor.isWallClockMetric(
        identifier: "CPU Cycles") == false)
  }

  @Test("Maps test method names to baseline entry keys")
  func mapsTestNamesToEntryKeys() {
    let node: [String: Any] = [
      "name": "test_fetchUnreadCountsSnapshot_micro()",
      "identifier": "MicroBenchmarkTests/test_fetchUnreadCountsSnapshot_micro()",
    ]
    #expect(
      MicroBenchmarkMetricsExtractor.microBenchmarkKey(forNode: node)
        == "fetchUnreadCountsSnapshot_micro")

    let nonMicro: [String: Any] = [
      "name": "test_sidebar_click_signpost()",
      "identifier": "PerfSignpostTests/test_sidebar_click_signpost()",
    ]
    #expect(MicroBenchmarkMetricsExtractor.microBenchmarkKey(forNode: nonMicro) == nil)
  }

  // MARK: - Fixture

  /// A minimal xcresulttool-shaped JSON tree carrying:
  /// - Four `MicroBenchmarkTests` leaves with `performanceMetrics` arrays,
  ///   each holding a single WallClockTime metric in seconds.
  /// - One unrelated `PerfSignpostTests` leaf to confirm the extractor
  ///   ignores non-MicroBenchmark nodes.
  static let fixtureTestsJSON: String = """
    {
      "testNodes": [
        {
          "name": "FeederTests",
          "children": [
            {
              "name": "MicroBenchmarkTests",
              "identifier": "FeederTests/MicroBenchmarkTests",
              "children": [
                {
                  "name": "test_fetchUnreadCountsSnapshot_micro()",
                  "identifier": "MicroBenchmarkTests/test_fetchUnreadCountsSnapshot_micro()",
                  "performanceMetrics": [
                    {
                      "identifier": "com.apple.dt.XCTMetric_Clock.time.monotonic",
                      "displayName": "Clock Monotonic Time",
                      "measurements": [0.024, 0.025, 0.026, 0.025, 0.024]
                    }
                  ]
                },
                {
                  "name": "test_fetchEntrySections_category_micro()",
                  "identifier": "MicroBenchmarkTests/test_fetchEntrySections_category_micro()",
                  "performanceMetrics": [
                    {
                      "identifier": "com.apple.XCTPerformanceMetric_WallClockTime",
                      "measurements": [0.013, 0.014, 0.014, 0.015, 0.014]
                    }
                  ]
                },
                {
                  "name": "test_parseHTMLToBlocks_micro()",
                  "identifier": "MicroBenchmarkTests/test_parseHTMLToBlocks_micro()",
                  "performanceMetrics": [
                    {
                      "identifier": "com.apple.dt.XCTMetric_Clock.time.monotonic",
                      "measurements": [0.0014, 0.0015, 0.0016, 0.0015, 0.0015]
                    },
                    {
                      "identifier": "com.apple.dt.XCTMetric_Memory.peak_physical",
                      "measurements": [12345, 12345, 12345, 12345, 12345]
                    }
                  ]
                },
                {
                  "name": "test_groupEntriesByDay_micro()",
                  "identifier": "MicroBenchmarkTests/test_groupEntriesByDay_micro()",
                  "performanceMetrics": [
                    {
                      "displayName": "Clock Monotonic Time",
                      "measurements": [0.003, 0.003, 0.003, 0.003, 0.003]
                    }
                  ]
                }
              ]
            },
            {
              "name": "PerfSignpostTests",
              "identifier": "FeederTests/PerfSignpostTests",
              "children": [
                {
                  "name": "test_sidebar_click_signpost()",
                  "identifier": "PerfSignpostTests/test_sidebar_click_signpost()",
                  "performanceMetrics": [
                    {
                      "identifier": "com.apple.dt.XCTMetric_OSSignpost,name=sidebar-click",
                      "measurements": [0.004, 0.005, 0.004, 0.005, 0.005]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """
}

@Suite("MicroBenchmark comparator boundary behaviour")
struct MicroBenchmarkComparatorTests {
  @Test("Captured value at the tolerance ceiling passes")
  func capturedAtCeilingPasses() {
    let baseline = Self.makeBaseline(toleranceP: 20, entries: ["foo_micro": 10.0])
    let medians = MicroBenchmarkMedians(medianMsByName: ["foo_micro": 12.0])  // 10 * 1.20 = 12 exactly
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  @Test("Captured value just beyond the tolerance ceiling fails")
  func capturedBeyondCeilingFails() {
    let baseline = Self.makeBaseline(toleranceP: 20, entries: ["foo_micro": 10.0])
    let medians = MicroBenchmarkMedians(medianMsByName: ["foo_micro": 12.001])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == false)
  }

  @Test("Captured value below the baseline always passes")
  func capturedBelowBaselinePasses() {
    let baseline = Self.makeBaseline(toleranceP: 10, entries: ["foo_micro": 10.0])
    let medians = MicroBenchmarkMedians(medianMsByName: ["foo_micro": 5.0])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  @Test("Missing baseline entry SKIPs (does not FAIL)")
  func missingBaselineEntrySkips() {
    let baseline = Self.makeBaseline(
      toleranceP: 20,
      entries: ["foo_micro": Double?.none as Double?]
    )
    let medians = MicroBenchmarkMedians(medianMsByName: ["foo_micro": 1000.0])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  @Test("Missing capture for an existing baseline SKIPs")
  func missingCaptureSkips() {
    let baseline = Self.makeBaseline(toleranceP: 20, entries: ["foo_micro": 10.0])
    let medians = MicroBenchmarkMedians(medianMsByName: [:])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  @Test("Missing level1_microbench section SKIPs")
  func missingSectionSkips() {
    var baseline = Self.makeBaseline(toleranceP: 20, entries: ["foo_micro": 10.0])
    baseline.level1Microbench = nil
    let medians = MicroBenchmarkMedians(medianMsByName: ["foo_micro": 9999.0])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  @Test("A new (un-baselined) benchmark name SKIPs rather than poisoning the gate")
  func newBenchmarkSkips() {
    let baseline = Self.makeBaseline(toleranceP: 20, entries: ["foo_micro": 10.0])
    let medians = MicroBenchmarkMedians(medianMsByName: ["bar_micro": 5.0])
    #expect(compareMicroBenchmarkMedians(medians, baseline: baseline) == true)
  }

  // MARK: - Helpers

  static func makeBaseline(toleranceP: Double, entries: [String: Double?]) -> BaselineDocument {
    BaselineDocument(
      schemaVersion: 1,
      capturedOn: "test",
      capturedHostCPU: "test",
      level1Microbench: Level1Microbench(
        tolerancePct: toleranceP,
        capturedOn: "test",
        notes: nil,
        entries: entries.mapValues { Level1Entry(medianMs: $0) }
      ),
      level2Signposts: Level2Signposts(
        sidebarClickMedianMs: nil,
        articleClickMedianMs: nil,
        detailRenderMedianMs: nil,
        tolerancePct: 20,
        frameBudgetMs: 8.3
      ),
      level4Trace: Level4Trace(
        contentviewBodyGetterPct: ThresholdMetric(max: 9, captured: 0),
        contentviewUnreadEntriesGetterPct: ThresholdMetric(max: 0.1, captured: 0),
        microhangsGe250MsCount: ThresholdMetric(max: 5, captured: 1),
        fullHangsGe500MsCount: ThresholdMetric(max: 1, captured: 1)
      ),
      previousMainHEADRecord: nil
    )
  }
}
