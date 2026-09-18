import Observation
import SwiftUI

// MARK: - App-wide Font Settings

/// Owner of the user-selectable app-wide text size and the source of every
/// SwiftUI font alias the app renders.
///
/// `@Observable`, so a size change invalidates only the views that read a font
/// alias and leaves `ContentView`'s selection, focus, and scroll anchor
/// untouched. The `didSet` mirror persists the choice.
///
/// Every alias is built with `Font.system(size:)` times
/// `AppTextSize.scaleFactor`, because that is the only mechanism that changes
/// rendered text size on macOS: `.dynamicTypeSize(_:)` and `@ScaledMetric`
/// propagate the environment value without re-resolving `Font.body`.
@MainActor
@Observable
final class AppFontSettings {
  /// The active app-wide text size. A write notifies every consumer and
  /// persists the value. Nothing outside this class reads `scaleFactor`
  /// directly; the font aliases below are the interface.
  ///
  /// `didSet` does not fire during init, so `init(textSize:userDefaults:)` can
  /// seed a value without writing back to `UserDefaults`.
  var textSize: AppTextSize {
    didSet {
      guard textSize != oldValue else { return }
      userDefaults.set(textSize.rawValue, forKey: appTextSizeUserDefaultsKey)
      entryRowHeight = Self.computeEntryRowHeight(scale: textSize.scaleFactor)
      entryRowTextColumnHeight = Self.computeEntryRowTextColumnHeight(scale: textSize.scaleFactor)
    }
  }

  /// Row-height floor for the article list: the natural height of an
  /// `EntryRowView` at the current text size, so every row is exactly this
  /// tall. Stored, not computed — the font-metric reads must happen only when
  /// `textSize` changes, never in a view `body` (`STACK.md § 0 / § 4`).
  private(set) var entryRowHeight: CGFloat

  /// Fixed height of the row's text column at the current text size: two title
  /// lines, the domain line, two summary lines, and the gaps between them. The
  /// title takes one or two lines inside it and the summary fills the rest.
  /// Stored for the same reason as `entryRowHeight`, and recomputed with it.
  private(set) var entryRowTextColumnHeight: CGFloat

  /// Backing store for `textSize` persistence. A test passes a per-suite store,
  /// so it cannot leak into the developer's app preferences.
  @ObservationIgnored
  private let userDefaults: UserDefaults

  /// Shipping init: reads the persisted value so the first frame uses the
  /// user's previous choice. A missing key reads back as `0`, which is not a
  /// valid `AppTextSize`, so the fallback below resolves a missing or invalid
  /// value to medium.
  convenience init() {
    let stored = UserDefaults.standard.integer(forKey: appTextSizeUserDefaultsKey)
    let resolved = AppTextSize(rawValue: stored) ?? .medium
    self.init(textSize: resolved, userDefaults: .standard)
  }

  /// Injected init for previews and tests, so each one pins its own size and
  /// its own `UserDefaults`. The assignment is direct, so `didSet` does not
  /// fire and construction has no write-back side effect.
  init(textSize: AppTextSize, userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    self.textSize = textSize
    self.entryRowHeight = Self.computeEntryRowHeight(scale: textSize.scaleFactor)
    self.entryRowTextColumnHeight = Self.computeEntryRowTextColumnHeight(scale: textSize.scaleFactor)
  }

  // MARK: - Scaling

  private var scale: CGFloat { textSize.scaleFactor }

  private func scaled(_ baseSize: CGFloat) -> CGFloat { baseSize * scale }

  // MARK: - Row metrics

  /// Row-height floor for the current `textSize`. Call it from `init` and the
  /// `textSize` setter only: the `NSFont` metric reads must never run per row
  /// or inside a `body`.
  private static func computeEntryRowHeight(scale: CGFloat) -> CGFloat {
    EntryRowMetrics.rowHeightFloor(scale: scale)
  }

  /// Fixed text-column height for the current `textSize`. Same call sites and
  /// frequency as `computeEntryRowHeight`.
  private static func computeEntryRowTextColumnHeight(scale: CGFloat) -> CGFloat {
    EntryRowMetrics.textColumnHeight(scale: scale)
  }

  // MARK: - Article reading surfaces

  /// Hero title in the article detail view, and `<h1>` rendering.
  var articleTitle: Font { .system(size: scaled(26), weight: .bold) }

  /// `<h2>` rendering and sidebar section headers.
  var sectionHeader: Font { .system(size: scaled(22), weight: .bold) }

  /// `<h3>` rendering inside structured article blocks.
  var subsectionHeader: Font { .system(size: scaled(17), weight: .bold) }

  /// `<h4>` rendering inside structured article blocks.
  var minorHeader: Font { .system(size: scaled(15), weight: .bold) }

  /// Reader-pane fallback for `<h5>` and `<h6>`. Kept distinct from `headline`
  /// so either can be retuned alone.
  var minorInlineHeading: Font { .system(size: scaled(13), weight: .semibold) }

  /// Reader prose: paragraphs, list items, blockquotes.
  var body: Font { .system(size: scaled(13)) }

  /// Monospaced reader prose for `<pre><code>` blocks.
  var codeBlock: Font { .system(size: scaled(13), design: .monospaced) }

  // MARK: - Row and list surfaces

  /// Article-list row title. The call site decides the weight with
  /// `.fontWeight(_:)`, which overrides the weight set here.
  var rowTitle: Font { .system(size: scaled(EntryRowMetrics.titleBaseSize), weight: .semibold) }

  /// Row summary excerpt below the title.
  var rowSummary: Font { .system(size: scaled(EntryRowMetrics.summaryBaseSize)) }

  /// Uppercase feed name and timestamp beneath a row. The base size keeps the
  /// smallest text-size setting above the macOS HIG legibility floor, which
  /// uppercase text reaches first.
  var rowFeedName: Font { .system(size: scaled(EntryRowMetrics.metaBaseSize)) }

  // MARK: - Sheets, settings, metadata

  /// Sheet titles.
  var headline: Font { .system(size: scaled(13), weight: .semibold) }

  /// Form field labels and inline secondary text.
  var caption: Font { .system(size: scaled(11)) }

  /// Compact rows in the management views.
  var bodyMedium: Font { .system(size: scaled(13), weight: .medium) }

  /// Article header metadata: date, author, domain.
  var metadata: Font { .system(size: scaled(11), weight: .medium) }

  /// Sync and classification status under the sidebar header. The base size
  /// keeps the smallest text-size setting above the macOS HIG legibility floor.
  var status: Font { .system(size: scaled(12)) }

  /// Day-section labels in the entry list.
  var sectionLabel: Font { .system(size: scaled(11), weight: .medium) }

  /// Sidebar unread-count digits: quieter than `metadata` and `caption`, and
  /// kept distinct from `caption` so the badge retunes on its own. The base
  /// size keeps the smallest text-size setting above the macOS HIG legibility
  /// floor.
  var sidebarBadge: Font { .system(size: scaled(12), weight: .regular) }
}
