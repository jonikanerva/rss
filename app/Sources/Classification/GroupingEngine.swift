import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "Grouping")

/// Groups classified entries by storyKey into StoryGroup records.
///
/// Grouping logic:
/// - Entries with the same storyKey are grouped together.
/// - Similar storyKeys (sharing a significant overlap of tokens) are merged.
/// - Each group gets a headline derived from the longest (most descriptive) title.
/// - Group timestamp is the earliest article date (per VISION.md).
/// - Entries with unique storyKeys remain ungrouped (standalone in timeline).
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
            // Fetch all entries with storyKeys
            var entryDescriptor = FetchDescriptor<Entry>()
            entryDescriptor.sortBy = [SortDescriptor(\Entry.publishedAt, order: .reverse)]
            let entries = try context.fetch(entryDescriptor)
            let classifiedEntries = entries.filter { $0.storyKey != nil && !$0.storyKey!.isEmpty }

            guard !classifiedEntries.isEmpty else {
                progress = "No classified entries to group"
                isGrouping = false
                return
            }

            // Delete existing groups (full rebuild — simple and correct)
            let groupDescriptor = FetchDescriptor<StoryGroup>()
            let existingGroups = try context.fetch(groupDescriptor)
            for group in existingGroups {
                context.delete(group)
            }

            // Cluster entries by storyKey similarity
            let clusters = clusterByStoryKey(classifiedEntries)

            // Create StoryGroup for clusters with 2+ entries
            var groupCount = 0
            for (canonicalKey, clusterEntries) in clusters {
                guard clusterEntries.count >= 2 else { continue }

                let headline = generateHeadline(from: clusterEntries)
                let earliestDate = clusterEntries.map(\.publishedAt).min() ?? Date()

                let group = StoryGroup(
                    storyKey: canonicalKey,
                    headline: headline,
                    earliestDate: earliestDate
                )
                group.entryCount = clusterEntries.count
                context.insert(group)

                // Update entries with the canonical storyKey
                for entry in clusterEntries {
                    entry.storyKey = canonicalKey
                }

                groupCount += 1
            }

            try context.save()
            progress = "Created \(groupCount) story groups"
            logger.info("Grouping complete: \(groupCount) groups from \(classifiedEntries.count) entries")
        } catch {
            progress = "Grouping error: \(error.localizedDescription)"
            logger.error("Grouping failed: \(error.localizedDescription)")
        }

        isGrouping = false
    }

    // MARK: - Clustering

    /// Clusters entries by storyKey similarity.
    /// Entries with identical keys are grouped first, then similar keys are merged.
    private func clusterByStoryKey(_ entries: [Entry]) -> [(String, [Entry])] {
        // First pass: exact storyKey grouping
        var keyToEntries: [String: [Entry]] = [:]
        for entry in entries {
            let key = entry.storyKey ?? "ungrouped"
            keyToEntries[key, default: []].append(entry)
        }

        // Second pass: merge similar keys using token overlap
        let keys = Array(keyToEntries.keys).sorted()
        var mergedClusters: [(String, [Entry])] = []
        var consumed = Set<String>()

        for key in keys {
            if consumed.contains(key) { continue }

            var cluster = keyToEntries[key] ?? []
            var canonicalKey = key
            consumed.insert(key)

            // Find similar keys to merge
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

                // Merge if significant token overlap (>= 50% Jaccard similarity)
                if jaccard >= 0.5 {
                    cluster.append(contentsOf: keyToEntries[otherKey] ?? [])
                    consumed.insert(otherKey)
                    // Use shorter key as canonical
                    if otherKey.count < canonicalKey.count {
                        canonicalKey = otherKey
                    }
                }
            }

            mergedClusters.append((canonicalKey, cluster))
        }

        return mergedClusters
    }

    // MARK: - Headline generation

    /// Generates a human-readable headline from a group of entries.
    /// Uses the longest (most descriptive) title from the group.
    private func generateHeadline(from entries: [Entry]) -> String {
        let titles = entries.compactMap(\.title).filter { !$0.isEmpty }
        guard let bestTitle = titles.max(by: { $0.count < $1.count }) else {
            return "Story Group"
        }
        return bestTitle
    }
}
