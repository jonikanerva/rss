import Foundation

// MARK: - Article resource policy

/// The one external-resource policy for both reader modes (`STACK.md § 8`).
/// An article loads only its images, from their original hosts, over https; an
/// http image URL is upgraded. No frame loads, and the page never navigates by
/// itself. A link opens in the default browser only on a user click, and only
/// for http and https.
nonisolated enum ArticleResourcePolicy {
  static let imageSchemes: Set<String> = ["https"]
  static let linkSchemes: Set<String> = ["http", "https"]

  /// The https URL that the reader loads for an image source, or `nil` when
  /// the policy blocks the source. A relative source has no scheme and is
  /// blocked: the native reader has no base URL.
  static func imageURL(_ source: String) -> URL? {
    guard var components = URLComponents(string: source),
      let scheme = components.scheme?.lowercased(),
      components.host?.isEmpty == false
    else { return nil }
    if scheme == "http" { components.scheme = "https" }
    guard let url = components.url, let resolved = url.scheme?.lowercased(),
      imageSchemes.contains(resolved)
    else { return nil }
    return url
  }

  static func allowsLinkOpen(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return linkSchemes.contains(scheme)
  }

  /// The CSP of the web reader. `data:` serves the inline favicon only; the
  /// renderer never emits another `data:` source. `upgrade-insecure-requests`
  /// upgrades an http image before `img-src` checks it. Tests pass an extra
  /// image scheme that a `WKURLSchemeHandler` can observe.
  static func contentSecurityPolicy(imageSources: [String] = ["https:"]) -> String {
    [
      "default-src 'none'",
      "img-src \((imageSources + ["data:"]).joined(separator: " "))",
      "style-src 'unsafe-inline'",
      "base-uri 'none'",
      "form-action 'none'",
      "upgrade-insecure-requests",
    ].joined(separator: "; ")
  }
}

// MARK: - Web reader navigation

/// What the web reader does with one navigation request.
nonisolated enum ArticleNavigationDecision: Equatable, Sendable {
  case allow
  case cancel
  case openInBrowser(URL)
}

/// Decide one navigation of the article web view. Only the HTML load that
/// Feeder starts itself may load a document. A user click on an http or https
/// link opens the default browser. Every other navigation is cancelled: a meta
/// refresh, a redirect, a form, a frame, and a link with another scheme.
nonisolated func articleNavigationDecision(
  isUserClick: Bool,
  isMainFrame: Bool,
  url: URL?,
  isPendingProgrammaticLoad: Bool
) -> ArticleNavigationDecision {
  if isUserClick {
    guard let url, ArticleResourcePolicy.allowsLinkOpen(url) else { return .cancel }
    return .openInBrowser(url)
  }
  return isMainFrame && isPendingProgrammaticLoad ? .allow : .cancel
}
