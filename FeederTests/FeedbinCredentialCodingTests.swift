import Foundation
import Testing

@testable import Feeder

/// Covers the pure item codec only. No test here may call a `SecItem…`
/// function: the test host runs in the owner's real app container and Keychain.
@Suite("Feedbin credential coding")
struct FeedbinCredentialCodingTests {
  private static let stored = FeedbinCredentials(username: "reader@example.com", password: "stored-secret")

  @Test(arguments: [
    FeedbinCredentialCodingTests.stored,
    FeedbinCredentials(username: "lukija+feeds@example.fi", password: #"p"ä\ss/wörd {} 🔑"#),
    FeedbinCredentials(username: "", password: ""),
  ])
  func itemRoundTripsThePair(credentials: FeedbinCredentials) throws {
    let item = try KeychainFeedbinCredentialStore.encodeItem(credentials)
    #expect(try KeychainFeedbinCredentialStore.decodeItem(item) == credentials)
  }

  @Test
  func itemIsAJSONObjectWithExactlyBothValues() throws {
    let item = try KeychainFeedbinCredentialStore.encodeItem(Self.stored)
    let object = try JSONSerialization.jsonObject(with: Data(item.utf8)) as? [String: String]
    #expect(object == ["username": "reader@example.com", "password": "stored-secret"])
  }

  @Test
  func storedFormatDecodes() throws {
    let item = #"{"username":"reader@example.com","password":"stored-secret"}"#
    #expect(try KeychainFeedbinCredentialStore.decodeItem(item) == Self.stored)
  }

  @Test(arguments: [
    "",
    "stored-secret",
    "{}",
    "[]",
    "null",
    #"{"username":"reader@example.com"}"#,
    #"{"username":7,"password":"stored-secret"}"#,
    #"{"username":"reader@example.com","password":"stored-secret""#,
  ])
  func undecodableDataIsAFailedRead(item: String) {
    #expect(throws: KeychainError.encodingFailed) {
      try KeychainFeedbinCredentialStore.decodeItem(item)
    }
  }

  @Test(arguments: [
    #"{"username":"","password":"stored-secret"}"#,
    #"{"username":"reader@example.com","password":""}"#,
    #"{"username":"","password":""}"#,
  ])
  func decodedEmptyFieldIsNoAccountNotAFailedRead(item: String) throws {
    #expect(try !KeychainFeedbinCredentialStore.decodeItem(item).isComplete)
  }
}
