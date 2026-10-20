import SwiftUI
import WebKit

// MARK: - Static resource loading

/// Load a bundle resource as a UTF-8 string. Used by the host view to cache
/// immutable template + CSS files in static `let` bindings.
nonisolated func loadStaticResource(_ name: String, ext: String) -> String {
  guard let url = Bundle.main.url(forResource: name, withExtension: ext),
    let contents = try? String(contentsOf: url, encoding: .utf8)
  else {
    return ""
  }
  return contents
}

// MARK: - Bare-key routing

/// Where a bare keypress inside the article web view routes. `nonisolated`, so
/// the classifier below and its tests can use the `Equatable` conformance.
nonisolated enum BareKeyRoute: Equatable, Sendable {
  case j, k, r, b
}

/// Decides whether a key event is one of the app's bare-key shortcuts, with
/// shift allowed, or belongs to the web view. Any other modifier, any
/// non-matching character, and Tab, Escape and the mark-all-read chord all
/// return `nil`, so the event falls through to the superclass.
///
/// It lives in the interface layer because it speaks `NSEvent.ModifierFlags`,
/// and is `nonisolated` so the truth table is testable without AppKit plumbing.
nonisolated func bareKeyRoute(
  characters: String?,
  modifiers: NSEvent.ModifierFlags
) -> BareKeyRoute? {
  guard modifiers.intersection([.command, .option, .control]).isEmpty else {
    return nil
  }
  switch characters {
  case "j", "J": return .j
  case "k", "K": return .k
  case "r", "R": return .r
  case "b", "B": return .b
  default: return nil
  }
}

// MARK: - Bare-key forwarding web view

/// `WKWebView` subclass that routes the app's bare-key shortcuts to the same
/// actions the SwiftUI handlers use.
///
/// Once the user clicks into the article the web view is first responder, so
/// key events travel the AppKit responder chain and never reach SwiftUI. The
/// interception therefore lives in this wrapped adapter (`STACK.md § 2`). A
/// handled action consumes the event; anything else falls through, so
/// scrolling, selection and copy stay untouched. Tab, Escape and the
/// mark-all-read chord are not forwarded.
private final class BareKeyForwardingWebView: WKWebView {
  var bareKeyActions = BareKeyActions()

  override func keyDown(with event: NSEvent) {
    guard
      let route = bareKeyRoute(
        characters: event.characters, modifiers: event.modifierFlags)
    else {
      super.keyDown(with: event)
      return
    }
    let result: KeyPress.Result =
      switch route {
      case .j: bareKeyActions.onJ()
      case .k: bareKeyActions.onK()
      case .r: bareKeyActions.onR()
      case .b: bareKeyActions.onB()
      }
    if result != .handled {
      super.keyDown(with: event)
    }
  }
}

// MARK: - Article Web View

struct ArticleWebView: NSViewRepresentable {
  let entry: Entry
  /// Pre-rendered article HTML. The host computes it on a background task, so
  /// the sanitisation and template injection stay off MainActor.
  let renderedHTML: String
  /// The same actions the SwiftUI handlers dispatch, forwarded into the AppKit
  /// subclass above so the shortcuts keep working while the web view is first
  /// responder.
  @Environment(\.bareKeyActions)
  private var bareKeyActions

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = ArticleWebConfiguration.make()
    let webView = BareKeyForwardingWebView(frame: .zero, configuration: config)
    webView.bareKeyActions = bareKeyActions
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    // Refresh the forwarded actions before the reload guard below: the
    // environment rebuilds its closures even when the entry and HTML are
    // unchanged.
    (webView as? BareKeyForwardingWebView)?.bareKeyActions = bareKeyActions
    // Re-load when the entry changes or the rendered HTML changes. Hashing the
    // HTML keeps the guard cheap: comparing the strings would allocate on every
    // diff.
    let entryID = entry.feedbinEntryID
    let htmlHash = renderedHTML.hashValue
    guard
      context.coordinator.currentEntryID != entryID
        || context.coordinator.currentHTMLHash != htmlHash
    else { return }
    context.coordinator.currentEntryID = entryID
    context.coordinator.currentHTMLHash = htmlHash

    context.coordinator.load(renderedHTML, baseURL: URL(string: entry.url))
  }

  // MARK: - Coordinator

  /// Loads the article HTML and enforces `articleNavigationDecision`. A load
  /// waits until the shared cookie policy applies, so no request of the
  /// article can store or send a cookie.
  final class Coordinator: NSObject, WKNavigationDelegate {
    private struct ArticleLoad {
      let html: String
      let baseURL: URL?
    }

    weak var webView: WKWebView?
    var currentEntryID: Int?
    var currentHTMLHash: Int?
    /// True from `loadHTMLString` until its main-frame decision. Feeder starts
    /// no other load in that time, so the next main-frame decision without a
    /// user click belongs to this load. Any later one is a meta refresh or a
    /// redirect, and the policy cancels it.
    private var isAwaitingLoadDecision = false
    /// The newest load that arrived while a decision was pending. It replaces
    /// an older queued load, and starts after that decision.
    private var queuedLoad: ArticleLoad?
    private var loadTask: Task<Void, Never>?
    private var queuedStartTask: Task<Void, Never>?

    func load(_ html: String, baseURL: URL?) {
      loadTask?.cancel()
      loadTask = nil
      let load = ArticleLoad(html: html, baseURL: baseURL)
      guard ArticleWebConfiguration.isCookiePolicyApplied else {
        loadTask = Task {
          await ArticleWebConfiguration.applyCookiePolicy()
          guard !Task.isCancelled else { return }
          request(load)
        }
        return
      }
      request(load)
    }

    private func request(_ load: ArticleLoad) {
      guard !isAwaitingLoadDecision else {
        queuedLoad = load
        return
      }
      start(load)
    }

    /// The stale-load branch of the decision sets the flag before this call, so
    /// a load in that gap queues. A missing web view clears the flag again.
    private func start(_ load: ArticleLoad) {
      guard let webView else {
        isAwaitingLoadDecision = false
        return
      }
      isAwaitingLoadDecision = true
      webView.loadHTMLString(load.html, baseURL: load.baseURL)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
      let isUserClick = navigationAction.navigationType == .linkActivated
      let isLoadDecision = isMainFrame && !isUserClick && isAwaitingLoadDecision
      if isLoadDecision {
        isAwaitingLoadDecision = false
        if let queuedLoad {
          // The queued load is newer, so this load is stale. It starts after
          // this decision returns: a load started inside the decision would
          // replace the navigation that the decision is for.
          self.queuedLoad = nil
          isAwaitingLoadDecision = true
          queuedStartTask = Task { start(queuedLoad) }
          return .cancel
        }
      }
      let decision = articleNavigationDecision(
        isUserClick: isUserClick,
        isMainFrame: isMainFrame,
        url: navigationAction.request.url,
        isPendingProgrammaticLoad: isLoadDecision
      )
      switch decision {
      case .allow:
        return .allow
      case .cancel:
        return .cancel
      case .openInBrowser(let url):
        NSWorkspace.shared.open(url)
        return .cancel
      }
    }

    /// A terminated web content process drops a pending decision, so the queued
    /// load starts now. The terminated load does not restart: an article that
    /// ends the process each time would loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      isAwaitingLoadDecision = false
      guard let queuedLoad else { return }
      self.queuedLoad = nil
      start(queuedLoad)
    }
  }
}

// MARK: - Configuration

/// The web view configuration that the article reader and `WebKitPreheat`
/// share (`STACK.md § 8`): JavaScript off, and one in-memory website data
/// store that refuses cookies.
@MainActor
enum ArticleWebConfiguration {
  static let dataStore = WKWebsiteDataStore.nonPersistent()
  private(set) static var isCookiePolicyApplied = false
  private static var cookiePolicyTask: Task<Void, Never>?

  static func make() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    config.websiteDataStore = dataStore
    startCookiePolicy()
    return config
  }

  /// Returns when the cookie policy of `dataStore` is `.disallow`.
  static func applyCookiePolicy() async {
    await startCookiePolicy().value
  }

  @discardableResult
  private static func startCookiePolicy() -> Task<Void, Never> {
    if let cookiePolicyTask { return cookiePolicyTask }
    let task = Task {
      await dataStore.httpCookieStore.setCookiePolicy(.disallow)
      isCookiePolicyApplied = true
    }
    cookiePolicyTask = task
    return task
  }
}
