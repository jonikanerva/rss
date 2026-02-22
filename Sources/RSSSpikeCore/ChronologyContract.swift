import Foundation

public struct TimelineItem: Equatable, Sendable {
    public let id: String
    public let canonicalTimestamp: Date

    public init(id: String, canonicalTimestamp: Date) {
        self.id = id
        self.canonicalTimestamp = canonicalTimestamp
    }
}

public struct ChronologyReport: Equatable, Sendable {
    public let inversionCount: Int
    public let adjacentPairCount: Int
    public let inversionRate: Double

    public init(inversionCount: Int, adjacentPairCount: Int, inversionRate: Double) {
        self.inversionCount = inversionCount
        self.adjacentPairCount = adjacentPairCount
        self.inversionRate = inversionRate
    }
}

public enum ChronologyContract {
    public static func sortNewestFirst(_ items: [TimelineItem]) -> [TimelineItem] {
        items.sorted { lhs, rhs in
            if lhs.canonicalTimestamp != rhs.canonicalTimestamp {
                return lhs.canonicalTimestamp > rhs.canonicalTimestamp
            }

            return lhs.id < rhs.id
        }
    }

    public static func report(for items: [TimelineItem]) -> ChronologyReport {
        let adjacentPairCount = max(0, items.count - 1)
        guard adjacentPairCount > 0 else {
            return ChronologyReport(inversionCount: 0, adjacentPairCount: adjacentPairCount, inversionRate: 0)
        }

        var inversionCount = 0
        for index in 0..<adjacentPairCount {
            let current = items[index]
            let next = items[index + 1]
            if current.canonicalTimestamp < next.canonicalTimestamp {
                inversionCount += 1
            }
        }

        let inversionRate = Double(inversionCount) / Double(adjacentPairCount)
        return ChronologyReport(
            inversionCount: inversionCount,
            adjacentPairCount: adjacentPairCount,
            inversionRate: inversionRate
        )
    }
}
