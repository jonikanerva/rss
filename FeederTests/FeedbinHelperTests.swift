import Foundation
import Testing

@testable import Feeder

// MARK: - FeedbinClient pure helpers

struct FeedbinHelperTests {
  // MARK: - Link Header Parsing

  @Test
  func hasNextPageWithNextLink() {
    #expect(hasNextPageInLinkHeader("<https://api.feedbin.com/v2/entries.json?page=2>; rel=\"next\"") == true)
  }

  @Test
  func hasNextPageWithoutNextLink() {
    #expect(hasNextPageInLinkHeader("<https://api.feedbin.com/v2/entries.json?page=1>; rel=\"prev\"") == false)
  }

  @Test
  func hasNextPageNilHeader() {
    #expect(hasNextPageInLinkHeader(nil) == false)
  }

  @Test
  func hasNextPageEmptyString() {
    #expect(hasNextPageInLinkHeader("") == false)
  }

  // MARK: - Date Formatting for Feedbin API

  @Test
  func formatDateProducesISO8601() {
    let date = Date(timeIntervalSince1970: 0)
    let result = formatDateForFeedbin(date)
    #expect(result.contains("1970-01-01"))
    #expect(result.contains("T"))
  }

  @Test
  func formatDateIncludesFractionalSeconds() {
    let date = Date(timeIntervalSince1970: 1.5)
    let result = formatDateForFeedbin(date)
    #expect(result.contains("."))
  }

  // MARK: - HTTP Status Code Mapping

  @Test
  func successReturnsNil() {
    #expect(mapHTTPStatus(200) == nil)
    #expect(mapHTTPStatus(201) == nil)
    #expect(mapHTTPStatus(299) == nil)
  }

  @Test
  func unauthorizedMapped() {
    if case .unauthorized = mapHTTPStatus(401)! {
      // pass
    } else {
      Issue.record("Expected unauthorized")
    }
  }

  @Test
  func forbiddenMapped() {
    if case .forbidden = mapHTTPStatus(403)! {
      // pass
    } else {
      Issue.record("Expected forbidden")
    }
  }

  @Test
  func notFoundMapped() {
    if case .notFound = mapHTTPStatus(404)! {
      // pass
    } else {
      Issue.record("Expected notFound")
    }
  }

  @Test
  func rateLimitedMapped() {
    if case .rateLimited = mapHTTPStatus(429)! {
      // pass
    } else {
      Issue.record("Expected rateLimited")
    }
  }

  @Test
  func serverErrorMapped() {
    if case .httpError(let code) = mapHTTPStatus(500)! {
      #expect(code == 500)
    } else {
      Issue.record("Expected httpError")
    }
  }
}
