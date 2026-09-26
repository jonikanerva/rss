import Foundation
import Security
import Testing

@testable import Feeder

/// Covers the pure status mapping only. No test here may call a `SecItem…`
/// function: the test host runs in the owner's real app container and Keychain.
@Suite("KeychainHelper status rule")
struct KeychainHelperTests {
  private static let failedStatuses: [OSStatus] = [
    errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecParam, -1,
  ]

  @Test
  func successReturnsTheStoredValue() throws {
    #expect(try KeychainHelper.decodeReadResult(status: errSecSuccess, data: Data("sk-test".utf8)) == "sk-test")
  }

  @Test
  func emptyDataStaysAnEmptyValue() throws {
    #expect(try KeychainHelper.decodeReadResult(status: errSecSuccess, data: Data()) == "")
  }

  @Test(arguments: [nil, Data([0xC3, 0x28]), Data([0xFF])] as [Data?])
  func successWithoutUTF8DataIsAFailedRead(data: Data?) {
    #expect(throws: KeychainError.encodingFailed) {
      try KeychainHelper.decodeReadResult(status: errSecSuccess, data: data)
    }
  }

  @Test
  func missingItemIsNoKey() throws {
    #expect(try KeychainHelper.decodeReadResult(status: errSecItemNotFound, data: nil) == nil)
  }

  @Test(arguments: KeychainHelperTests.failedStatuses)
  func everyOtherStatusIsAFailedRead(status: OSStatus) {
    #expect(throws: KeychainError.osStatus(status)) {
      try KeychainHelper.decodeReadResult(status: status, data: Data("sk-test".utf8))
    }
  }

  @Test
  func probeReportsWhetherTheItemExists() throws {
    #expect(try KeychainHelper.decodeExistsResult(status: errSecSuccess))
    #expect(try !KeychainHelper.decodeExistsResult(status: errSecItemNotFound))
  }

  @Test(arguments: KeychainHelperTests.failedStatuses)
  func failedProbeIsNotAMissingItem(status: OSStatus) {
    #expect(throws: KeychainError.osStatus(status)) {
      try KeychainHelper.decodeExistsResult(status: status)
    }
  }
}
