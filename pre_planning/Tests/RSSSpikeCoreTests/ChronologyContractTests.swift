import XCTest
@testable import RSSSpikeCore

final class ChronologyContractTests: XCTestCase {
    func testSortNewestFirstByCanonicalTimestamp() {
        let older = TimelineItem(id: "old", canonicalTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = TimelineItem(id: "new", canonicalTimestamp: Date(timeIntervalSince1970: 1_700_000_100))

        let sorted = ChronologyContract.sortNewestFirst([older, newer])

        XCTAssertEqual(sorted.map(\.id), ["new", "old"])
    }

    func testInversionRateIsZeroForChronologicalList() {
        let items = [
            TimelineItem(id: "a", canonicalTimestamp: Date(timeIntervalSince1970: 100)),
            TimelineItem(id: "b", canonicalTimestamp: Date(timeIntervalSince1970: 90)),
            TimelineItem(id: "c", canonicalTimestamp: Date(timeIntervalSince1970: 80)),
        ]

        let report = ChronologyContract.report(for: items)

        XCTAssertEqual(report.inversionRate, 0)
        XCTAssertEqual(report.inversionCount, 0)
    }

    func testInversionRateCountsOutOfOrderPair() {
        let items = [
            TimelineItem(id: "a", canonicalTimestamp: Date(timeIntervalSince1970: 100)),
            TimelineItem(id: "b", canonicalTimestamp: Date(timeIntervalSince1970: 120)),
            TimelineItem(id: "c", canonicalTimestamp: Date(timeIntervalSince1970: 80)),
        ]

        let report = ChronologyContract.report(for: items)

        XCTAssertEqual(report.inversionCount, 1)
        XCTAssertEqual(report.adjacentPairCount, 2)
        XCTAssertEqual(report.inversionRate, 0.5)
    }
}
