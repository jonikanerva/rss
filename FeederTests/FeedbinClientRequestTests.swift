import Foundation
import Testing

@testable import Feeder

nonisolated struct FeedbinRequestCase: Sendable, CustomTestStringConvertible {
  let testDescription: String
  let responseBody: String
  let method: String
  let url: String
  let authorization: String?
  let call: @Sendable (FeedbinClient) async throws -> Void
}

/// Answers every request with HTTP 200 and `body`.
private actor FeedbinRequestRecorder {
  private(set) var requests: [URLRequest] = []
  private let body: Data

  init(body: String) {
    self.body = Data(body.utf8)
  }

  func send(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
    else { throw URLError(.badURL) }
    return (body, response)
  }
}

@Suite("Feedbin client requests")
struct FeedbinClientRequestTests {
  nonisolated private static let basicAuthorization = "Basic dXNlckBleGFtcGxlLmNvbTpmYWtlLXBhc3N3b3Jk"
  nonisolated private static let extractURL =
    "https://extract.feedbin.com/parser/feedbin/0a1b2c3d4e5f?base64_url=aHR0cHM6Ly9leGFtcGxlLmNvbS9hcnRpY2xl"

  nonisolated private static let requestCases: [FeedbinRequestCase] = [
    FeedbinRequestCase(
      testDescription: "verifyCredentials", responseBody: "", method: "GET",
      url: "https://api.feedbin.com/v2/authentication.json", authorization: basicAuthorization,
      call: { _ = try await $0.verifyCredentials() }),
    FeedbinRequestCase(
      testDescription: "fetchSubscriptions", responseBody: "[]", method: "GET",
      url: "https://api.feedbin.com/v2/subscriptions.json", authorization: basicAuthorization,
      call: { _ = try await $0.fetchSubscriptions() }),
    FeedbinRequestCase(
      testDescription: "fetchIcons", responseBody: "[]", method: "GET",
      url: "https://api.feedbin.com/v2/icons.json", authorization: basicAuthorization,
      call: { _ = try await $0.fetchIcons() }),
    FeedbinRequestCase(
      testDescription: "fetchUnreadEntryIDs", responseBody: "[]", method: "GET",
      url: "https://api.feedbin.com/v2/unread_entries.json", authorization: basicAuthorization,
      call: { _ = try await $0.fetchUnreadEntryIDs() }),
    FeedbinRequestCase(
      testDescription: "fetchEntries", responseBody: "[]", method: "GET",
      url: "https://api.feedbin.com/v2/entries.json?page=2&per_page=100&since=1970-01-01T00:00:00.000Z",
      authorization: basicAuthorization,
      call: { _ = try await $0.fetchEntries(since: Date(timeIntervalSince1970: 0), page: 2) }),
    FeedbinRequestCase(
      testDescription: "deleteUnreadEntries", responseBody: "", method: "DELETE",
      url: "https://api.feedbin.com/v2/unread_entries.json", authorization: basicAuthorization,
      call: { try await $0.deleteUnreadEntries([1, 2]) }),
    FeedbinRequestCase(
      testDescription: "fetchExtractedContent", responseBody: "{}", method: "GET",
      url: extractURL, authorization: nil,
      call: { _ = try await $0.fetchExtractedContent(from: extractURL) }),
  ]

  private static func client(sendingTo recorder: FeedbinRequestRecorder) -> FeedbinClient {
    FeedbinClient(username: "user@example.com", password: "fake-password", send: { try await recorder.send($0) })
  }

  @Test(arguments: FeedbinClientRequestTests.requestCases)
  func onlyAPIRequestsCarryTheCredentials(_ requestCase: FeedbinRequestCase) async throws {
    let recorder = FeedbinRequestRecorder(body: requestCase.responseBody)
    try await requestCase.call(Self.client(sendingTo: recorder))
    let requests = await recorder.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.httpMethod == requestCase.method)
    #expect(request.url?.absoluteString == requestCase.url)
    #expect(request.value(forHTTPHeaderField: "Authorization") == requestCase.authorization)
  }

  @Test
  func deleteSendsAtMostOneThousandIDsPerRequest() async throws {
    let recorder = FeedbinRequestRecorder(body: "")
    try await Self.client(sendingTo: recorder).deleteUnreadEntries(Array(1...1001))
    let requests = await recorder.requests
    #expect(requests.count == 2)
    for request in requests {
      #expect(request.httpMethod == "DELETE")
      #expect(request.url?.absoluteString == "https://api.feedbin.com/v2/unread_entries.json")
      #expect(request.value(forHTTPHeaderField: "Authorization") == Self.basicAuthorization)
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    }
    let bodies = try requests.map { request in
      let body = try #require(request.httpBody)
      return try JSONDecoder().decode([String: [Int]].self, from: body)
    }
    #expect(bodies == [["unread_entries": Array(1...1000)], ["unread_entries": [1001]]])
  }
}
