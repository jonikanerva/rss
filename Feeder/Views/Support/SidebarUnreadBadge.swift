import SwiftUI

/// Sidebar trailing unread-count label: quiet scalable text rather than
/// `.badge(_:)`, whose system pill has no public styling hook on macOS and
/// clashes with the calm reader tone (`VISION.md`). Hidden at zero, so a
/// fully-read category renders no stray "0".
///
/// A separate view, so the `AppFontSettings` read lives here and a size change
/// invalidates only the badge sub-tree. Monospaced digits keep the trailing
/// column aligned as counts change.
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
