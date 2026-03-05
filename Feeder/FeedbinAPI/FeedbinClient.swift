import Foundation
import OSLog

private nonisolated(unsafe) let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")

/// Feedbin API v2 client using HTTP Basic auth and async/await.
/// Reference: https://github.com/feedbin/feedbin-api
actor FeedbinClient {
    private let baseURL = URL(string: "https://api.feedbin.com/v2/")!
    private let session: URLSession
    private let credential: String // Base64-encoded "user:password"
    private let decoder: JSONDecoder

    init(username: String, password: String) {
        let credentialData = "\(username):\(password)".data(using: .utf8)!
        self.credential = credentialData.base64EncodedString()

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Authorization": "Basic \(credentialData.base64EncodedString())"
        ]
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Feedbin uses ISO 8601 with fractional seconds
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Try with fractional seconds first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) {
                return date
            }
            // Fallback: try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date: \(string)"
            )
        }
        self.decoder = decoder
    }

    // MARK: - Authentication

    /// Verify credentials. Returns true if valid.
    func verifyCredentials() async throws -> Bool {
        let url = baseURL.appending(path: "authentication.json")
        let (_, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - Subscriptions

    /// Fetch all subscriptions (feeds the user is subscribed to).
    func fetchSubscriptions() async throws -> [FeedbinSubscription] {
        let url = baseURL.appending(path: "subscriptions.json")
        let (data, response) = try await session.data(from: url)
        try checkResponse(response)
        return try decoder.decode([FeedbinSubscription].self, from: data)
    }

    // MARK: - Entries

    /// Fetch entries with optional `since` date for incremental sync.
    /// Returns entries and whether there are more pages.
    func fetchEntries(since: Date? = nil, page: Int = 1, perPage: Int = 100) async throws -> FeedbinEntriesPage {
        var components = URLComponents(url: baseURL.appending(path: "entries.json"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "per_page", value: "\(perPage)")
        ]
        if let since {
            queryItems.append(URLQueryItem(name: "since", value: formatDate(since)))
        }
        components.queryItems = queryItems

        let (data, response) = try await session.data(from: components.url!)
        try checkResponse(response)
        let entries = try decoder.decode([FeedbinEntry].self, from: data)

        // Parse Link header for pagination
        let hasNextPage = parseLinkHeader(response)

        return FeedbinEntriesPage(entries: entries, hasNextPage: hasNextPage)
    }

    /// Fetch all entries, auto-paginating. Uses `since` for incremental sync.
    func fetchAllEntries(since: Date? = nil) async throws -> [FeedbinEntry] {
        var allEntries: [FeedbinEntry] = []
        var page = 1

        while true {
            let result = try await fetchEntries(since: since, page: page)
            allEntries.append(contentsOf: result.entries)
            logger.info("Fetched page \(page): \(result.entries.count) entries (\(allEntries.count) total so far)")

            if !result.hasNextPage || result.entries.isEmpty {
                break
            }
            page += 1
        }

        logger.info("Fetched all entries: \(allEntries.count) total across \(page) pages")
        return allEntries
    }

    // MARK: - Extracted Content

    /// Fetch extracted full content from Feedbin's Mercury Parser.
    /// The `extractedContentURL` comes from the entry's `extracted_content_url` field.
    func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? {
        guard let url = URL(string: extractedContentURL) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try decoder.decode(FeedbinExtractedContent.self, from: data)
    }

    // MARK: - Helpers

    private func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FeedbinError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw FeedbinError.unauthorized
        case 403:
            throw FeedbinError.forbidden
        case 404:
            throw FeedbinError.notFound
        case 429:
            throw FeedbinError.rateLimited
        default:
            throw FeedbinError.httpError(statusCode: http.statusCode)
        }
    }

    private func parseLinkHeader(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let linkHeader = http.value(forHTTPHeaderField: "Links")
                ?? http.value(forHTTPHeaderField: "Link") else {
            return false
        }
        return linkHeader.contains("rel=\"next\"")
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Errors

nonisolated enum FeedbinError: Error, LocalizedError {
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Feedbin"
        case .unauthorized: "Invalid Feedbin credentials"
        case .forbidden: "Access forbidden"
        case .notFound: "Resource not found"
        case .rateLimited: "Rate limited by Feedbin"
        case .httpError(let code): "HTTP error \(code)"
        }
    }
}
