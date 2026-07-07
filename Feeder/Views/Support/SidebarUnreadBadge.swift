import SwiftUI

/// Sidebar trailing unread-count label. Replaces `.badge(_:)` so the count
/// renders as quiet, scalable text instead of macOS's high-contrast system
/// pill — which has no public styling hook on macOS and clashed with the
/// "calm reader" tone (`VISION.md`). Hidden when the count is zero so
/// a fully-read category does not render a stray "0".
///
/// Why a separate view (not a `Text` view modifier soup at the call site):
/// the read of `AppFontSettings` lives here, so toggling the size invalidates
/// only the badge sub-tree per row rather than the whole sidebar `List`
/// row. The monospaced-digit treatment keeps the trailing column visually
/// aligned across rows as counts change.
struct SidebarUnreadBadge: View {
  let count: Int

  @Environment(AppFontSettings.self)
  private var fontSettings

  var body: some View {
    if count > 0 {
      Text(count, format: .number)
        .font(fontSettings.sidebarBadge)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .accessibilityLabel("\(count) unread")
    }
  }
}

#Preview("Sidebar unread badges") {
  VStack(alignment: .leading, spacing: 12) {
    HStack {
      Text("Technology")
      Spacer()
      SidebarUnreadBadge(count: 3)
    }
    HStack {
      Text("Apple")
      Spacer()
      SidebarUnreadBadge(count: 42)
    }
    HStack {
      Text("Empty (zero hides)")
      Spacer()
      SidebarUnreadBadge(count: 0)
    }
  }
  .padding()
  .frame(width: 220)
  .environment(AppFontSettings(textSize: .medium))
}
