import Foundation
import OSLog

nonisolated private let credentialLogger = Logger(subsystem: "com.feeder.app", category: "CredentialSaving")

/// Validate Feedbin credentials with the API and persist them only on success.
/// Writes username to UserDefaults and password to Keychain. Returns `true`
/// when credentials were verified and saved; `false` when the server rejected
/// them. Throws on network/transport errors from the verify call. A Keychain
/// failure is logged and swallowed — we'd rather finish onboarding with the
/// username in UserDefaults than block the user on a rare persistence fault.
nonisolated func saveFeedbinCredentials(
  username: String,
  password: String
) async throws -> Bool {
  let client = FeedbinClient(username: username, password: password)
  let valid = try await client.verifyCredentials()
  guard valid else { return false }
  UserDefaults.standard.set(username, forKey: "feedbin_username")
  do {
    try KeychainHelper.save(key: KeychainHelper.feedbinPasswordKey, value: password)
  } catch {
    credentialLogger.error("Failed to persist Feedbin password in keychain: \(String(describing: error))")
  }
  return true
}
