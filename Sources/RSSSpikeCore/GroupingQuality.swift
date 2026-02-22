import Foundation

public enum StoryPairType: String, Equatable, Sendable {
    case sameStory = "same_story"
    case differentStory = "different_story"
    case uncertain = "uncertain"
}

public struct StoryPairLabel: Equatable, Sendable {
    public let itemIDA: String
    public let itemIDB: String
    public let label: StoryPairType

    public init(itemIDA: String, itemIDB: String, label: StoryPairType) {
        self.itemIDA = itemIDA
        self.itemIDB = itemIDB
        self.label = label
    }
}

public struct GroupingQualityMetrics: Equatable, Sendable {
    public let evaluatedPairCount: Int
    public let sameStoryPairCount: Int
    public let differentStoryPairCount: Int
    public let groupPurity: Double
    public let splitRate: Double
    public let overmergeRate: Double

    public init(
        evaluatedPairCount: Int,
        sameStoryPairCount: Int,
        differentStoryPairCount: Int,
        groupPurity: Double,
        splitRate: Double,
        overmergeRate: Double
    ) {
        self.evaluatedPairCount = evaluatedPairCount
        self.sameStoryPairCount = sameStoryPairCount
        self.differentStoryPairCount = differentStoryPairCount
        self.groupPurity = groupPurity
        self.splitRate = splitRate
        self.overmergeRate = overmergeRate
    }
}

public enum GroupingQualityEvaluator {
    public static func evaluate(
        labels: [StoryPairLabel],
        predictedGroupByItemID: [String: String]
    ) -> GroupingQualityMetrics {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0

        var sameStoryPairCount = 0
        var differentStoryPairCount = 0

        for pair in labels {
            guard pair.label != .uncertain else {
                continue
            }
            guard let groupA = predictedGroupByItemID[pair.itemIDA],
                  let groupB = predictedGroupByItemID[pair.itemIDB]
            else {
                continue
            }

            let predictedSame = (groupA == groupB)
            switch pair.label {
            case .sameStory:
                sameStoryPairCount += 1
                if predictedSame {
                    truePositive += 1
                } else {
                    falseNegative += 1
                }
            case .differentStory:
                differentStoryPairCount += 1
                if predictedSame {
                    falsePositive += 1
                }
            case .uncertain:
                break
            }
        }

        let evaluatedPairCount = sameStoryPairCount + differentStoryPairCount
        let groupPurity = ratio(numerator: truePositive, denominator: truePositive + falsePositive)
        let splitRate = ratio(numerator: falseNegative, denominator: sameStoryPairCount)
        let overmergeRate = ratio(numerator: falsePositive, denominator: differentStoryPairCount)

        return GroupingQualityMetrics(
            evaluatedPairCount: evaluatedPairCount,
            sameStoryPairCount: sameStoryPairCount,
            differentStoryPairCount: differentStoryPairCount,
            groupPurity: groupPurity,
            splitRate: splitRate,
            overmergeRate: overmergeRate
        )
    }

    private static func ratio(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }
}
