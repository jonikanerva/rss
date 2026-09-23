import Foundation
import Testing

@testable import Feeder

@Suite("Cloud session")
struct CloudSessionTests {
  @Test(arguments: [30] as [TimeInterval])
  func sessionUsesTheCloudPolicy(requestTimeout: TimeInterval) {
    let configuration = CloudSession(requestTimeout: requestTimeout).configuration
    #expect(configuration.timeoutIntervalForRequest == requestTimeout)
    #expect(configuration.timeoutIntervalForResource == 60)
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpAdditionalHeaders == nil)
    #expect(configuration.waitsForConnectivity == false)
    #expect(configuration.identifier == nil)
  }

  /// Keep the header name in lower case. A case-sensitive lookup must fail this
  /// test.
  @Test
  func responseReadsRetryAfterCaseInsensitively() throws {
    let url = try #require(URL(string: "https://ai-gateway.vercel.sh/v1/evaluate"))
    let data = Data("body".utf8)
    let http = try #require(
      HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/2", headerFields: ["retry-after": "120"]))
    let response = try #require(ClassificationHTTPResponse(data: data, response: http))
    #expect(response.statusCode == 429)
    #expect(response.retryAfter == "120")
    #expect(response.data == data)
    let plain = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    #expect(ClassificationHTTPResponse(data: data, response: plain) == nil)
  }
}
