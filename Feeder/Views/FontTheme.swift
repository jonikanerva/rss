import SwiftUI

// MARK: - Centralized Font Theme

/// Semantic font aliases for the app. Every entry maps to an Apple text style
/// (`.body`, `.headline`, …) so SwiftUI honours the user's macOS *Larger Text*
/// accessibility setting via Dynamic Type. Roles that share the same Apple
/// style keep distinct names so the call site documents its intent and a
/// future redesign can split them apart without touching every caller.
///
/// macOS HIG mapping (default sizes in parentheses, all scale with Dynamic Type):
/// - `.largeTitle` (26pt) — article hero titles.
/// - `.title`      (22pt) — section headers.
/// - `.title2/3`   (17/15pt) — secondary headings inside reader content.
/// - `.headline`   (13pt, semibold) — row titles, sheet titles.
/// - `.body`       (13pt) — reader prose, form text fields.
/// - `.callout`    (12pt) — row summaries, body-adjacent supporting text.
/// - `.subheadline` (11pt) — used in two flavours below:
///   - bare `.subheadline` for form labels and inline secondary text (`caption`).
///   - `.subheadline.weight(.medium)` where metadata needs a touch more
///     emphasis without jumping a full size (`metadata`, `sectionLabel`).
/// - `.caption`    (10pt) — status strings, uppercase feed-name footers.
enum FontTheme {
  // MARK: - Article reading surfaces

  /// Hero title in the article detail view and `<h1>` rendering.
  static var articleTitle: Font { .largeTitle.weight(.bold) }

  /// `<h2>` rendering and sidebar section headers.
  static var sectionHeader: Font { .title.weight(.bold) }

  /// `<h3>` rendering inside structured article blocks.
  static var subsectionHeader: Font { .title2.weight(.bold) }

  /// `<h4>` rendering inside structured article blocks.
  static var minorHeader: Font { .title3.weight(.bold) }

  /// Reader prose: paragraphs, list items, blockquotes.
  static var body: Font { .body }

  /// Monospaced reader prose for `<pre><code>` blocks.
  static var codeBlock: Font { .body.monospaced() }

  // MARK: - Row and list surfaces

  /// Article list row title. Weight is decided at the call site (semibold for
  /// unread, regular for read) — keeping the alias unweighted lets the caller
  /// override without having to spell out `.system(.headline)`.
  static var rowTitle: Font { .headline }

  /// Row summary excerpt below the title.
  static var rowSummary: Font { .callout }

  /// Uppercase feed name / timestamp footer beneath a row.
  static var rowFeedName: Font { .caption }

  // MARK: - Sheets, settings, metadata

  /// Sheet titles ("New Category", "OpenAI API Key", …).
  static var headline: Font { .headline }

  /// Form field labels and inline secondary text. `.subheadline` keeps a
  /// readable size at default Dynamic Type while still feeling subordinate to
  /// `.body`.
  static var caption: Font { .subheadline }

  /// Compact rows in management views (category list, folder list).
  static var bodyMedium: Font { .body.weight(.medium) }

  /// Article header metadata (date, author, domain).
  static var metadata: Font { .subheadline.weight(.medium) }

  /// Sync / classification status strings under the sidebar header.
  static var status: Font { .caption }

  /// Section labels in the entry list (e.g. "Today", "Yesterday").
  static var sectionLabel: Font { .subheadline.weight(.medium) }

  // MARK: - Colors

  /// Color used for the inline domain text under a row title.
  static let domainPillColor = Color(nsColor: .secondaryLabelColor)
}
