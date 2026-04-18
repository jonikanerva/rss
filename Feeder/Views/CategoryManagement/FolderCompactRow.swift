import SwiftUI

/// Compact list row for a folder inside the management view. Displays a folder
/// icon, the folder name, and an Edit button. `isDropTarget` paints an
/// accent-colored highlight frame when a drag is hovering.
struct FolderCompactRow: View {
  let displayName: String
  let isDropTarget: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      Text(displayName)
        .font(FontTheme.bodyMedium)
      Spacer()
      Button("Edit") {
        onEdit()
      }
    }
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
