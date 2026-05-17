import SwiftUI

/// Compact list row for a folder header inside the management view. Displays
/// a folder icon, the folder name, and an Edit button.
struct FolderCompactRow: View {
  let displayName: String
  let onEdit: () -> Void
  @Environment(AppFontSettings.self)
  private var fontSettings

  var body: some View {
    HStack {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      Text(displayName)
        .font(fontSettings.bodyMedium)
      Spacer()
      Button("Edit") {
        onEdit()
      }
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
  }
}
