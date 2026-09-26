import Foundation
import Security
import Testing

@testable import Feeder

// MARK: - Pure read rule

/// No test here may call a `SecItem…` function or read `UserDefaults.standard`:
/// the test host runs in the owner's real app container.
@Suite("Feedbin credential read rule")
struct FeedbinCredentialReadRuleTests {
  @Test(arguments: [nil, ""] as [String?])
  func noUsernameMeansNoAccountWithoutAPasswordRead(username: String?) throws {
    var passwordReads = 0
    let credentials = try KeychainFeedbinCredentialStore.credentials(username: username) {
      () throws(KeychainError) -> String? in
      passwordReads += 1
      return "secret"
    }
    #expect(credentials == nil)
    #expect(passwordReads == 0)
  }

  @Test(arguments: [KeychainError.osStatus(errSecAuthFailed), .osStatus(errSecUserCanceled), .encodingFailed])
  func failedPasswordReadRethrows(failure: KeychainError) {
    #expect(throws: failure) {
      try KeychainFeedbinCredentialStore.credentials(username: "reader@example.com") {
        () throws(KeychainError) -> String? in
        throw failure
      }
    }
  }

  @Test
  func missingPasswordMeansNoAccount() throws {
    #expect(try KeychainFeedbinCredentialStore.credentials(username: "reader@example.com") { nil } == nil)
  }

  @Test
  func storedPairComesBackUnchanged() throws {
    let credentials = try KeychainFeedbinCredentialStore.credentials(username: "reader@example.com") { "" }
    #expect(credentials == FeedbinCredentials(username: "reader@example.com", password: ""))
    #expect(credentials?.isComplete == false)
  }

  @Test
  func memoryStoreRejectsAnAddOverAnExistingAccount() async throws {
    let stored = FeedbinCredentials(username: "reader@example.com", password: "stored-secret")
    let store = MemoryFeedbinCredentialStore(credentials: stored)
    await #expect(throws: KeychainError.osStatus(errSecDuplicateItem)) {
      try await store.add(FeedbinCredentials(username: "new@example.com", password: "new-secret"))
    }
    #expect(try await store.load() == stored)
  }
}
