import Foundation

public struct FeedEntry: Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let title: String
    public let summary: String
    public let publishedAt: Date?
    public let updatedAt: Date?
    public let fetchedAt: Date?

    public init(
        id: String,
        sourceID: String,
        title: String,
        summary: String,
        publishedAt: Date?,
        updatedAt: Date?,
        fetchedAt: Date?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
    }
}

public struct CategoryPrediction: Equatable, Sendable {
    public let label: String
    public let confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

public protocol EntryCategorizer: Sendable {
    func predict(for entry: FeedEntry) -> CategoryPrediction?
}

public enum CategorySource: Equatable, Sendable {
    case model
    case fallback
}

public struct ProcessedItem: Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let title: String
    public let canonicalTimestamp: Date
    public let category: String
    public let categorySource: CategorySource
    public let groupID: String

    public init(
        id: String,
        sourceID: String,
        title: String,
        canonicalTimestamp: Date,
        category: String,
        categorySource: CategorySource,
        groupID: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.canonicalTimestamp = canonicalTimestamp
        self.category = category
        self.categorySource = categorySource
        self.groupID = groupID
    }
}

public struct PipelineOutput: Equatable, Sendable {
    public let items: [ProcessedItem]
    public let chronologyReport: ChronologyReport

    public init(items: [ProcessedItem], chronologyReport: ChronologyReport) {
        self.items = items
        self.chronologyReport = chronologyReport
    }
}

public struct BaselinePipeline: Sendable {
    public let categorizer: any EntryCategorizer
    public let fallbackCategory: String
    public let confidenceThreshold: Double

    public init(
        categorizer: any EntryCategorizer,
        fallbackCategory: String,
        confidenceThreshold: Double
    ) {
        self.categorizer = categorizer
        self.fallbackCategory = fallbackCategory
        self.confidenceThreshold = confidenceThreshold
    }

    public func process(entries: [FeedEntry]) -> PipelineOutput {
        var items: [ProcessedItem] = []
        items.reserveCapacity(entries.count)

        for entry in entries {
            guard let canonicalTimestamp = CanonicalTimestampResolver.resolve(
                publishedAt: entry.publishedAt,
                updatedAt: entry.updatedAt,
                fetchedAt: entry.fetchedAt
            ) else {
                continue
            }

            let categoryAssignment = assignCategory(for: entry)
            let groupID = GroupingPolicy.groupID(for: entry.title)

            let processed = ProcessedItem(
                id: entry.id,
                sourceID: entry.sourceID,
                title: entry.title,
                canonicalTimestamp: canonicalTimestamp,
                category: categoryAssignment.label,
                categorySource: categoryAssignment.source,
                groupID: groupID
            )
            items.append(processed)
        }

        let sortedTimeline = ChronologyContract.sortNewestFirst(
            items.map { TimelineItem(id: $0.id, canonicalTimestamp: $0.canonicalTimestamp) }
        )

        let sortedByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let sortedItems = sortedTimeline.compactMap { sortedByID[$0.id] }
        let chronologyReport = ChronologyContract.report(
            for: sortedItems.map { TimelineItem(id: $0.id, canonicalTimestamp: $0.canonicalTimestamp) }
        )

        return PipelineOutput(items: sortedItems, chronologyReport: chronologyReport)
    }

    private func assignCategory(for entry: FeedEntry) -> (label: String, source: CategorySource) {
        guard let prediction = categorizer.predict(for: entry),
              prediction.confidence >= confidenceThreshold,
              prediction.label.isEmpty == false
        else {
            return (label: fallbackCategory, source: .fallback)
        }

        return (label: prediction.label, source: .model)
    }
}

private enum GroupingPolicy {
    static func groupID(for title: String) -> String {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        if normalized.isEmpty {
            return "group:untitled"
        }

        return "group:\(normalized)"
    }
}
