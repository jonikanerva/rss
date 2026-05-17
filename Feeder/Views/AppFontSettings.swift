import Observation
import SwiftUI

// MARK: - App-wide Font Settings

/// Owner of the user-selectable app-wide text size and the source of every
/// SwiftUI font alias the app renders. Replaces the previous
/// `@MainActor static var FontTheme.current` global plus the
/// `.id(appTextSize)`-driven scene tear-down that caused state resets
/// (sidebar selection, article selection, scroll position) every time the
/// user changed the picker.
///
/// **Why `@Observable` instead of `@AppStorage` + a static:**
/// - SwiftUI sees property reads through `@Environment(AppFontSettings.self)`
///   and invalidates only the views that actually read a font alias, leaving
///   `ContentView`'s `@State` (selection, focus, scroll anchor) untouched.
///   `.id(appTextSize)` is no longer needed.
/// - Persistence stays — the `didSet` mirror keeps the same `UserDefaults`
///   key (`appTextSizeUserDefaultsKey`) so a re-launch restores the user's
///   choice.
///
/// **Why each font alias is a computed property:**
/// On macOS the only mechanism that produces visible text-size change is
/// constructing fonts with `Font.system(size:)` and multiplying the base
/// size by `AppTextSize.scaleFactor`. `.dynamicTypeSize(_:)` and
/// `@ScaledMetric` propagate the environment value but do not re-resolve
/// `Font.body` (verified previously by visual measurement on macOS 26).
@MainActor
@Observable
final class AppFontSettings {
  /// The active app-wide text size. Writing here notifies every
  /// `@Environment(AppFontSettings.self)` consumer and persists the new
  /// value so the choice survives relaunch. Reads go through the computed
  /// font aliases below; nothing outside this class reads `scaleFactor`
  /// directly.
  var textSize: AppTextSize {
    didSet {
      guard textSize != oldValue else { return }
      UserDefaults.standard.set(textSize.rawValue, forKey: appTextSizeUserDefaultsKey)
    }
  }

  init() {
    // Match the `@AppStorage` storage shape: a missing key reads back as `0`
    // from `UserDefaults.integer(forKey:)`. `AppTextSize(rawValue: 0) == nil`
    // by construction (the enum starts at `1`), so the `?? .medium` fallback
    // wins on a fresh install / cleared preferences — preserving the same
    // default the picker uses.
    let stored = UserDefaults.standard.integer(forKey: appTextSizeUserDefaultsKey)
    self.textSize = AppTextSize(rawValue: stored) ?? .medium
  }

  // MARK: - Scaling

  private var scale: CGFloat { textSize.scaleFactor }

  private func scaled(_ baseSize: CGFloat) -> CGFloat { baseSize * scale }

  // MARK: - Article reading surfaces

  /// Hero title in the article detail view and `<h1>` rendering.
  /// Mirrors `.largeTitle.bold` at 26pt base.
  var articleTitle: Font { .system(size: scaled(26), weight: .bold) }

  /// `<h2>` rendering and sidebar section headers.
  /// Mirrors `.title.bold` at 22pt base.
  var sectionHeader: Font { .system(size: scaled(22), weight: .bold) }

  /// `<h3>` rendering inside structured article blocks.
  /// Mirrors `.title2.bold` at 17pt base.
  var subsectionHeader: Font { .system(size: scaled(17), weight: .bold) }

  /// `<h4>` rendering inside structured article blocks.
  /// Mirrors `.title3.bold` at 15pt base.
  var minorHeader: Font { .system(size: scaled(15), weight: .bold) }

  /// Reader pane h5/h6 inline heading fallback. Distinct from `headline`
  /// (sheet titles) so a future reader redesign can retune one without
  /// affecting the other.
  /// Mirrors `.headline` at 13pt base, semibold.
  var minorInlineHeading: Font { .system(size: scaled(13), weight: .semibold) }

  /// Reader prose: paragraphs, list items, blockquotes.
  /// Mirrors `.body` at 13pt base.
  var body: Font { .system(size: scaled(13)) }

  /// Monospaced reader prose for `<pre><code>` blocks.
  /// Mirrors `.body.monospaced()` at 13pt base.
  var codeBlock: Font { .system(size: scaled(13), design: .monospaced) }

  // MARK: - Row and list surfaces

  /// Article list row title. Weight is decided at the call site (semibold for
  /// unread, regular for read) — call sites use `.fontWeight(_:)` which
  /// overrides the weight set here.
  /// Mirrors `.headline` at 13pt base, semibold.
  var rowTitle: Font { .system(size: scaled(13), weight: .semibold) }

  /// Row summary excerpt below the title.
  /// Mirrors `.callout` at 12pt base.
  var rowSummary: Font { .system(size: scaled(12)) }

  /// Uppercase feed name / timestamp footer beneath a row.
  /// Mirrors `.caption` at 10pt base.
  var rowFeedName: Font { .system(size: scaled(10)) }

  // MARK: - Sheets, settings, metadata

  /// Sheet titles ("New Category", "OpenAI API Key", …).
  /// Mirrors `.headline` at 13pt base, semibold.
  var headline: Font { .system(size: scaled(13), weight: .semibold) }

  /// Form field labels and inline secondary text.
  /// Mirrors `.subheadline` at 11pt base.
  var caption: Font { .system(size: scaled(11)) }

  /// Compact rows in management views (category list, folder list).
  /// Mirrors `.body.weight(.medium)` at 13pt base.
  var bodyMedium: Font { .system(size: scaled(13), weight: .medium) }

  /// Article header metadata (date, author, domain).
  /// Mirrors `.subheadline.weight(.medium)` at 11pt base.
  var metadata: Font { .system(size: scaled(11), weight: .medium) }

  /// Sync / classification status strings under the sidebar header.
  /// Mirrors `.caption` at 10pt base.
  var status: Font { .system(size: scaled(10)) }

  /// Section labels in the entry list (e.g. "Today", "Yesterday").
  /// Mirrors `.subheadline.weight(.medium)` at 11pt base.
  var sectionLabel: Font { .system(size: scaled(11), weight: .medium) }
}
