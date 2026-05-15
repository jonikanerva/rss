import Foundation
import Testing

@testable import Feeder

// MARK: - SyncError categorisation

/// Pure-function coverage for `categorizeSyncError(_:)`. The categorisation
/// drives the sidebar's recovery action (Retry vs Sign in again) and
/// `EntryListView`'s offline empty state — getting the mapping wrong silently
/// breaks both, so each branch gets its own dedicated test.
///
/// Assertions use `SyncError`'s `Equatable` conformance throughout — the
/// case **and** the carried message are pinned, so a regression that
/// swaps a case while keeping the same description still fails the test.
@Suite("SyncError categorisation")
struct SyncErrorTests {
  // MARK: - Network bucket

  @Test
  func notConnectedToInternetMapsToNetwork() {
    let error = URLError(.notConnectedToInternet)
    #expect(categorizeSyncError(error) == .network(error.localizedDescription))
  }

  @Test
  func timedOutMapsToNetwork() {
    let error = URLError(.timedOut)
    #expect(categorizeSyncError(error) == .network(error.localizedDescription))
  }

  @Test
  func networkConnectionLostMapsToNetwork() {
    let error = URLError(.networkConnectionLost)
    #expect(categorizeSyncError(error) == .network(error.localizedDescription))
  }

  @Test
  func cannotConnectToHostMapsToNetwork() {
    let error = URLError(.cannotConnectToHost)
    #expect(categorizeSyncError(error) == .network(error.localizedDescription))
  }

  @Test
  func server5xxMapsToNetwork() {
    let error = FeedbinError.httpError(statusCode: 503)
    #expect(categorizeSyncError(error) == .network(error.localizedDescription))
  }

  // MARK: - Auth bucket

  @Test
  func unauthorizedFeedbinErrorMapsToAuth() {
    let error = FeedbinError.unauthorized
    #expect(categorizeSyncError(error) == .authFailed(error.localizedDescription))
  }

  // MARK: - Other bucket

  @Test
  func httpError400MapsToOther() {
    let error = FeedbinError.httpError(statusCode: 400)
    #expect(categorizeSyncError(error) == .other(error.localizedDescription))
  }

  @Test
  func invalidResponseMapsToOther() {
    let error = FeedbinError.invalidResponse
    #expect(categorizeSyncError(error) == .other(error.localizedDescription))
  }

  @Test
  func nonURLErrorMapsToOther() {
    struct UnknownError: Error {}
    let error = UnknownError()
    #expect(categorizeSyncError(error) == .other(error.localizedDescription))
  }

  // MARK: - isNetworkError flag

  @Test
  func isNetworkErrorTrueOnlyForNetworkCase() {
    #expect(SyncError.network("x").isNetworkError)
    #expect(!SyncError.authFailed("x").isNetworkError)
    #expect(!SyncError.other("x").isNetworkError)
  }

  // MARK: - Message propagation

  @Test
  func messageIsPopulatedFromLocalizedDescription() {
    let error = URLError(.notConnectedToInternet)
    let categorised = categorizeSyncError(error)
    #expect(categorised.message == error.localizedDescription)
  }
}
