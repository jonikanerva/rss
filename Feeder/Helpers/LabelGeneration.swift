import Foundation

/// Generate a unique, URL-/SQL-safe label from a user-facing display name.
/// Lowercases, replaces spaces with underscores, strips non-alphanumerics, and
/// appends a random 4-digit suffix so labels remain unique within their domain
/// without the UI needing to check the whole set first.
nonisolated func makeUniqueLabel(from displayName: String, fallbackPrefix: String) -> String {
  let sanitized = displayName.lowercased()
    .replacingOccurrences(of: " ", with: "_")
    .filter { $0.isLetter || $0.isNumber || $0 == "_" }
  let base = sanitized.isEmpty ? fallbackPrefix : sanitized
  return "\(base)_\(Int.random(in: 1000...9999))"
}
