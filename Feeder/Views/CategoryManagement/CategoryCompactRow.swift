import SwiftUI

/// Compact list row for a category in the management view. The edit button is
/// hidden for a system category, and the enclosing drop zones own the drop
/// highlighting, not the row.
struct CategoryCompactRow: View {
  let displayName: String
  let descriptionPreview: String
  let depth: Int
  let isSystem: Bool
  let onEdit: () -> Void
  @Environment(AppFontSettings.self)
  private var fontSettings

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(fontSettings.bodyMedium)
        Text(descriptionPreview.prefix(50) + (descriptionPreview.count > 50 ? "…" : ""))
          .font(fontSettings.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if !isSystem {
        Button("Edit") {
          onEdit()
        }
      }
    }
    .padding(.leading, CGFloat(depth) * 20)
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
  }
}
