import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "Grouping")

// MARK: - Sendable DTOs for crossing actor boundaries

/// Lightweight input for grouping — extracted from SwiftData on main, processed on background.
private nonisolated struct GroupingInput: Sendable {
    let entryID: Int
    let storyKey: String
    let title: String
    let publishedAt: Date
}

/// Result of background clustering — applied to SwiftData on main.
private nonisolated struct ClusterResult: Sendable {
    let canonicalKey: String
    let headline: String
    let earliestDate: Date
    let entryCount: Int
    let entryIDs: [Int]
}

/// Groups classified entries by storyKey into StoryGroup records.
@MainActor
@Observable
final class GroupingEngine {
    private(set) var isGrouping = false
    private(set) var progress: String = ""

    /// Run grouping on all classified entries.
    func groupEntries(in context: ModelContext) async {
        guard !isGrouping else { return }
        isGrouping = true
        progress = "Grouping stories..."

        do {
            // Fetch all entries with storyKeys (fast, on main)
            var entryDescriptor = FetchDescriptor<Entry>()
            entryDescriptor.sortBy = [SortDescriptor(\Entry.publishedAt, order: .reverse)]
            let entries = try context.fetch(entryDescriptor)
            let classifiedEntries = entries.filter { $0.storyKey != nil && !$0.storyKey!.isEmpty }

            guard !classifiedEntries.isEmpty else {
                progress = "No classified entries to group"
                isGrouping = false
                return
            }

            logger.info("Grouping \(classifiedEntries.count) classified entries")
            progress = "Grouping \(classifiedEntries.count) entries..."

            // Delete existing groups (full rebuild)
            let groupDescriptor = FetchDescriptor<StoryGroup>()
            let existingGroups = try context.fetch(groupDescriptor)
            for group in existingGroups {
                context.delete(group)
            }
            logger.info("Cleared \(existingGroups.count) previous groups")

            // Extract lightweight data for background processing
            let inputs: [GroupingInput] = classifiedEntries.map { entry in
                GroupingInput(
                    entryID: entry.feedbinEntryID,
                    storyKey: entry.storyKey ?? "",
                    title: entry.title ?? "",
                    publishedAt: entry.publishedAt
                )
            }

            // Heavy O(n²) clustering on background thread
            progress = "Clustering by story similarity..."
            let clusterResults = await Task.detached(priority: .utility) {
                Self.clusterByStoryKey(inputs)
            }.value

            logger.info("Found \(clusterResults.count) story clusters with 2+ entries")

            // Apply results back to SwiftData on main
            let entriesByID = Dictionary(uniqueKeysWithValues: classifiedEntries.map { ($0.feedbinEntryID, $0) })

            var groupCount = 0
            var groupedEntryCount = 0
            for cluster in clusterResults {
                let group = StoryGroup(
                    storyKey: cluster.canonicalKey,
                    headline: cluster.headline,
                    earliestDate: cluster.earliestDate
                )
                group.entryCount = cluster.entryCount
                context.insert(group)

                for entryID in cluster.entryIDs {
                    entriesByID[entryID]?.storyKey = cluster.canonicalKey
                }

                groupCount += 1
                groupedEntryCount += cluster.entryCount
            }

            try context.save()
            let standaloneCount = classifiedEntries.count - groupedEntryCount
            progress = "Grouped: \(groupCount) stories (\(groupedEntryCount) entries), \(standaloneCount) standalone"
            logger.info("Grouping complete: \(groupCount) groups (\(groupedEntryCount) entries grouped), \(standaloneCount) standalone")
        } catch {
            progress = "Grouping error: \(error.localizedDescription)"
            logger.error("Grouping failed: \(error.localizedDescription)")
        }

        isGrouping = false
    }

    // MARK: - Clustering (nonisolated, runs on background thread)

    /// Clusters entries by storyKey similarity. Returns only clusters with 2+ entries.
    private nonisolated static func clusterByStoryKey(_ inputs: [GroupingInput]) -> [ClusterResult] {
        // First pass: exact storyKey grouping
        var keyToInputs: [String: [GroupingInput]] = [:]
        for input in inputs {
            keyToInputs[input.storyKey, default: []].append(input)
        }

        // Second pass: merge similar keys using token overlap
        let keys = Array(keyToInputs.keys).sorted()
        var mergedClusters: [(String, [GroupingInput])] = []
        var consumed = Set<String>()

        for key in keys {
            if consumed.contains(key) { continue }

            var cluster = keyToInputs[key] ?? []
            var canonicalKey = key
            consumed.insert(key)

            let keyTokens = Set(key.split(separator: "-").map(String.init))
            guard keyTokens.count >= 2 else {
                mergedClusters.append((canonicalKey, cluster))
                continue
            }

            for otherKey in keys {
                if consumed.contains(otherKey) { continue }
                let otherTokens = Set(otherKey.split(separator: "-").map(String.init))
                guard otherTokens.count >= 2 else { continue }

                let intersection = keyTokens.intersection(otherTokens)
                let union = keyTokens.union(otherTokens)
                let jaccard = Double(intersection.count) / Double(union.count)

                if jaccard >= 0.5 {
                    cluster.append(contentsOf: keyToInputs[otherKey] ?? [])
                    consumed.insert(otherKey)
                    if otherKey.count < canonicalKey.count {
                        canonicalKey = otherKey
                    }
                }
            }

            mergedClusters.append((canonicalKey, cluster))
        }

        // Only return clusters with 2+ entries
        return mergedClusters.compactMap { canonicalKey, clusterInputs in
            guard clusterInputs.count >= 2 else { return nil }

            let titles = clusterInputs.compactMap { $0.title.isEmpty ? nil : $0.title }
            let headline = titles.max(by: { $0.count < $1.count }) ?? "Story Group"
            let earliestDate = clusterInputs.map(\.publishedAt).min() ?? Date()

            return ClusterResult(
                canonicalKey: canonicalKey,
                headline: headline,
                earliestDate: earliestDate,
                entryCount: clusterInputs.count,
                entryIDs: clusterInputs.map(\.entryID)
            )
        }
    }
}
