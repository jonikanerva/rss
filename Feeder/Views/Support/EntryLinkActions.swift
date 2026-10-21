import AppKit

// MARK: - Entry link actions

extension NSWorkspace {
  /// Opens `url` in its default application without activating that
  /// application. Does nothing when no application can open `url`.
  func openInBackground(_ url: URL) {
    guard let applicationURL = urlForApplication(toOpen: url) else { return }
    let configuration = OpenConfiguration()
    configuration.activates = false
    open([url], withApplicationAt: applicationURL, configuration: configuration)
  }
}

/// The Edit → Copy action of the article list. It writes the link of the
/// selected article through `write`. A `nil` URL gives a `nil` action, which
/// disables Edit → Copy while the article list has focus.
func articleLinkCopyAction(url: URL?, write: @escaping (URL) -> Void) -> (() -> Void)? {
  guard let url else { return nil }
  return { write(url) }
}

extension NSPasteboard {
  /// Replaces the contents with one item that carries `url` as a URL and as
  /// plain text.
  ///
  /// Write only: a programmatic read of the general pasteboard shows a system
  /// privacy alert.
  func writeLink(_ url: URL) {
    clearContents()
    setString(url.absoluteString, forType: .URL)
    setString(url.absoluteString, forType: .string)
  }
}
