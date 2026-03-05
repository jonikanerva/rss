import Foundation

public struct FeedEntry: Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let title: String
    public let summary: String
    public let body: String?
    public let publishedAt: Date?
    public let updatedAt: Date?
    public let fetchedAt: Date?

    public init(
        id: String,
        sourceID: String,
        title: String,
        summary: String,
        body: String? = nil,
        publishedAt: Date?,
        updatedAt: Date?,
        fetchedAt: Date?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.body = body
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
    }
}

public struct CategoryScore: Equatable, Sendable {
    public let label: String
    public let confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

public struct CategoryPrediction: Equatable, Sendable {
    public let scores: [CategoryScore]
    public let storyKey: String?

    public init(scores: [CategoryScore], storyKey: String? = nil) {
        self.scores = scores
        self.storyKey = storyKey
    }

    public init(label: String, confidence: Double) {
        self.scores = [CategoryScore(label: label, confidence: confidence)]
        self.storyKey = nil
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
    public let categories: [String]
    public let category: String
    public let categorySource: CategorySource
    public let groupID: String

    public init(
        id: String,
        sourceID: String,
        title: String,
        canonicalTimestamp: Date,
        categories: [String],
        categorySource: CategorySource,
        groupID: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.canonicalTimestamp = canonicalTimestamp
        self.categories = categories
        self.category = categories.first ?? ""
        self.categorySource = categorySource
        self.groupID = groupID
    }
}

public struct TaxonomyHierarchy: Equatable, Sendable {
    public let ancestorsByCategory: [String: [String]]

    public init(ancestorsByCategory: [String: [String]]) {
        var cleaned: [String: [String]] = [:]
        cleaned.reserveCapacity(ancestorsByCategory.count)

        for (category, ancestors) in ancestorsByCategory {
            let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedCategory.isEmpty == false else {
                continue
            }

            cleaned[normalizedCategory] = uniquePreservingOrder(
                ancestors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
            )
        }

        self.ancestorsByCategory = cleaned
    }

    public static let empty = TaxonomyHierarchy(ancestorsByCategory: [:])

    public func propagate(labels: [String]) -> [String] {
        var propagated: [String] = []
        propagated.reserveCapacity(labels.count * 2)

        for label in labels {
            if let ancestors = ancestorsByCategory[label] {
                for ancestor in ancestors where propagated.contains(ancestor) == false {
                    propagated.append(ancestor)
                }
            }

            if propagated.contains(label) == false {
                propagated.append(label)
            }
        }

        return propagated
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
    public let hierarchy: TaxonomyHierarchy

    public init(
        categorizer: any EntryCategorizer,
        fallbackCategory: String,
        confidenceThreshold: Double,
        hierarchy: TaxonomyHierarchy = .empty
    ) {
        self.categorizer = categorizer
        self.fallbackCategory = fallbackCategory
        self.confidenceThreshold = confidenceThreshold
        self.hierarchy = hierarchy
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

            let categoryAssignment = assignCategories(for: entry)
            let groupID = GroupingPolicy.groupID(for: categoryAssignment.storyKey ?? entry.title)

            let processed = ProcessedItem(
                id: entry.id,
                sourceID: entry.sourceID,
                title: entry.title,
                canonicalTimestamp: canonicalTimestamp,
                categories: categoryAssignment.labels,
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

    private func assignCategories(for entry: FeedEntry) -> (labels: [String], source: CategorySource, storyKey: String?) {
        guard let prediction = categorizer.predict(for: entry) else {
            return ([fallbackCategory], .fallback, nil)
        }

        let acceptedLabels = prediction.scores.compactMap { score -> String? in
            let label = score.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.isEmpty == false else {
                return nil
            }

            guard score.confidence.isFinite, score.confidence >= confidenceThreshold else {
                return nil
            }

            return label
        }

        let uniqueAcceptedLabels = uniquePreservingOrder(acceptedLabels)
        let propagatedLabels = hierarchy.propagate(labels: uniqueAcceptedLabels)
        if propagatedLabels.isEmpty {
            return ([fallbackCategory], .fallback, nil)
        }

        return (propagatedLabels, .model, prediction.storyKey)
    }
}

private func uniquePreservingOrder(_ labels: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    result.reserveCapacity(labels.count)

    for label in labels where seen.contains(label) == false {
        seen.insert(label)
        result.append(label)
    }

    return result
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
