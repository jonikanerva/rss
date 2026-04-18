import Foundation

/// Validate Feedbin credentials with the API and persist them only on success.
/// Writes username to UserDefaults and password to Keychain. Returns `true`
/// when credentials were verified and saved; `false` when the server rejected
/// them. Throws on network/transport errors from the verify call.
nonisolated func saveFeedbinCredentials(
  username: String,
  password: String
) async throws -> Bool {
  let client = FeedbinClient(username: username, password: password)
  let valid = try await client.verifyCredentials()
  guard valid else { return false }
  UserDefaults.standard.set(username, forKey: "feedbin_username")
  try? KeychainHelper.save(key: "feedbin_password", value: password)
  return true
}
