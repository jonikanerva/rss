import SwiftUI

/// Compact list row for a category inside the management view. Displays the
/// name, a one-line description preview, and an Edit button (hidden for system
/// categories). `isDropTarget` paints an accent-colored highlight frame.
struct CategoryCompactRow: View {
  let displayName: String
  let descriptionPreview: String
  let depth: Int
  let isSystem: Bool
  let isDropTarget: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(FontTheme.bodyMedium)
        Text(descriptionPreview.prefix(50) + (descriptionPreview.count > 50 ? "…" : ""))
          .font(FontTheme.caption)
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
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
    )
  }
}
