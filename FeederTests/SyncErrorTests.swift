import Foundation
import Testing

@testable import Feeder

// MARK: - SyncError categorisation

/// Pure-function coverage for `categorizeSyncError(_:)`. The categorisation
/// drives the sidebar's recovery action (Retry vs Sign in again) and
/// `EntryListView`'s offline empty state — getting the mapping wrong silently
/// breaks both, so each branch gets its own dedicated test.
@Suite("SyncError categorisation")
struct SyncErrorTests {
  // MARK: - Network bucket

  @Test
  func notConnectedToInternetMapsToNetwork() {
    let error = URLError(.notConnectedToInternet)
    let categorised = categorizeSyncError(error)
    #expect(categorised.isNetworkError)
    if case .network = categorised {
    } else {
      Issue.record("Expected .network, got \(categorised)")
    }
  }

  @Test
  func timedOutMapsToNetwork() {
    let error = URLError(.timedOut)
    #expect(categorizeSyncError(error).isNetworkError)
  }

  @Test
  func networkConnectionLostMapsToNetwork() {
    let error = URLError(.networkConnectionLost)
    #expect(categorizeSyncError(error).isNetworkError)
  }

  @Test
  func cannotConnectToHostMapsToNetwork() {
    let error = URLError(.cannotConnectToHost)
    #expect(categorizeSyncError(error).isNetworkError)
  }

  @Test
  func server5xxMapsToNetwork() {
    let error = FeedbinError.httpError(statusCode: 503)
    #expect(categorizeSyncError(error).isNetworkError)
  }

  // MARK: - Auth bucket

  @Test
  func unauthorizedFeedbinErrorMapsToAuth() {
    let categorised = categorizeSyncError(FeedbinError.unauthorized)
    if case .authFailed = categorised {
    } else {
      Issue.record("Expected .authFailed, got \(categorised)")
    }
    #expect(!categorised.isNetworkError)
  }

  // MARK: - Other bucket

  @Test
  func httpError400MapsToOther() {
    let categorised = categorizeSyncError(FeedbinError.httpError(statusCode: 400))
    if case .other = categorised {
    } else {
      Issue.record("Expected .other for 4xx outside auth window, got \(categorised)")
    }
    #expect(!categorised.isNetworkError)
  }

  @Test
  func invalidResponseMapsToOther() {
    let categorised = categorizeSyncError(FeedbinError.invalidResponse)
    if case .other = categorised {
    } else {
      Issue.record("Expected .other, got \(categorised)")
    }
  }

  @Test
  func nonURLErrorMapsToOther() {
    struct UnknownError: Error {}
    let categorised = categorizeSyncError(UnknownError())
    if case .other = categorised {
    } else {
      Issue.record("Expected .other for unknown errors, got \(categorised)")
    }
  }

  // MARK: - Message propagation

  @Test
  func messageIsPopulatedFromLocalizedDescription() {
    let error = URLError(.notConnectedToInternet)
    let categorised = categorizeSyncError(error)
    #expect(!categorised.message.isEmpty)
  }
}
