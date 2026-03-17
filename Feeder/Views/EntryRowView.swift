import SwiftUI
import SwiftData

// MARK: - Entry Row View

struct EntryRowView: View {
    let entry: Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread indicator
            Circle()
                .fill(entry.isRead ? Color.clear : Color(hex: 0x5A9CFF))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(entry.title ?? "Untitled")
                    .font(.system(size: FontTheme.rowTitleSize, weight: entry.isRead ? .regular : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(entry.isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

                // Date — pre-computed, zero Calendar ops
                Text(entry.formattedDate)
                    .font(.system(size: FontTheme.captionSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isRead ? (entry.title ?? "Untitled") : "Unread, \(entry.title ?? "Untitled")")
        .accessibilityIdentifier("entry.row.\(entry.feedbinEntryID)")
    }
}

// MARK: - Preview

#Preview("Unread Entry") {
    unreadEntryRowPreview()
}

#Preview("Read Entry") {
    readEntryRowPreview()
}

@MainActor
private func unreadEntryRowPreview() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config)
    let context = container.mainContext

    let entry = Entry(
        feedbinEntryID: 1, title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
        author: "Tom Warren", url: "https://example.com/1",
        content: "<p>Apple today announced...</p>",
        summary: "Apple today announced the M5 Ultra.",
        extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-3600), createdAt: .now
    )
    entry.isRead = false
    entry.formattedDate = "Today, 15th Mar, 09:30"
    context.insert(entry)

    return EntryRowView(entry: entry)
        .modelContainer(container)
        .frame(width: 380)
        .padding()
}

@MainActor
private func readEntryRowPreview() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config)
    let context = container.mainContext

    let entry = Entry(
        feedbinEntryID: 2, title: "EU passes sweeping AI regulation requiring model transparency",
        author: nil, url: "https://example.com/2",
        content: nil,
        summary: "The European Union has approved comprehensive AI legislation.",
        extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-90000), createdAt: .now
    )
    entry.isRead = true
    entry.formattedDate = "Yesterday, 14th Mar, 08:30"
    context.insert(entry)

    return EntryRowView(entry: entry)
        .modelContainer(container)
        .frame(width: 380)
        .padding()
}
