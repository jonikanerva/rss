import Foundation

public enum CanonicalTimestampResolver {
    public static func resolve(
        publishedAt: Date?,
        updatedAt: Date?,
        fetchedAt: Date?
    ) -> Date? {
        if let publishedAt {
            return publishedAt
        }

        if let updatedAt {
            return updatedAt
        }

        return fetchedAt
    }
}
