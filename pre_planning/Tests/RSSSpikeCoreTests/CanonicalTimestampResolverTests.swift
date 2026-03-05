import XCTest
@testable import RSSSpikeCore

final class CanonicalTimestampResolverTests: XCTestCase {
    func testResolveUsesPublishedAtWhenAvailable() {
        let publishedAt = Date(timeIntervalSince1970: 1_000)
        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let fetchedAt = Date(timeIntervalSince1970: 3_000)

        let resolved = CanonicalTimestampResolver.resolve(
            publishedAt: publishedAt,
            updatedAt: updatedAt,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(resolved, publishedAt)
    }

    func testResolveFallsBackToUpdatedAt() {
        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let fetchedAt = Date(timeIntervalSince1970: 3_000)

        let resolved = CanonicalTimestampResolver.resolve(
            publishedAt: nil,
            updatedAt: updatedAt,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(resolved, updatedAt)
    }

    func testResolveFallsBackToFetchedAt() {
        let fetchedAt = Date(timeIntervalSince1970: 3_000)

        let resolved = CanonicalTimestampResolver.resolve(
            publishedAt: nil,
            updatedAt: nil,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(resolved, fetchedAt)
    }

    func testResolveReturnsNilWhenNoTimestampExists() {
        let resolved = CanonicalTimestampResolver.resolve(
            publishedAt: nil,
            updatedAt: nil,
            fetchedAt: nil
        )

        XCTAssertNil(resolved)
    }
}
