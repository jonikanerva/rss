import SwiftUI
import SwiftData

// MARK: - Date formatting

/// Formats date as "Today, 5th Mar, 21:24" / "Yesterday, 4th Mar, 9:23" / "Monday, 2nd Mar, 13:42"
private func formatEntryDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    let day = calendar.component(.day, from: date)
    let ordinal = ordinalSuffix(for: day)
    let month = date.formatted(.dateTime.month(.abbreviated))

    if calendar.isDateInToday(date) {
        return "Today, \(day)\(ordinal) \(month), \(time)"
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday, \(day)\(ordinal) \(month), \(time)"
    } else {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        return "\(weekday), \(day)\(ordinal) \(month), \(time)"
    }
}

private func ordinalSuffix(for day: Int) -> String {
    switch day {
    case 11, 12, 13: return "th"
    default:
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}

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
                    .font(.system(size: 15, weight: entry.isRead ? .regular : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(entry.isRead ? Color(nsColor: .tertiaryLabelColor) : .primary)

                // Date
                Text(formatEntryDate(entry.publishedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("entry.row.\(entry.feedbinEntryID)")
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        if !entry.isRead { parts.append("Unread") }
        parts.append(entry.title ?? "Untitled")
        return parts.joined(separator: ", ")
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
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, StoryGroup.self, configurations: config)
    let context = container.mainContext

    let entry = Entry(
        feedbinEntryID: 1, title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
        author: "Tom Warren", url: "https://example.com/1",
        content: "<p>Apple today announced...</p>",
        summary: "Apple today announced the M5 Ultra.",
        extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-3600), createdAt: .now
    )
    entry.isRead = false
    context.insert(entry)

    return EntryRowView(entry: entry)
        .modelContainer(container)
        .frame(width: 380)
        .padding()
}

@MainActor
private func readEntryRowPreview() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, StoryGroup.self, configurations: config)
    let context = container.mainContext

    let entry = Entry(
        feedbinEntryID: 2, title: "EU passes sweeping AI regulation requiring model transparency",
        author: nil, url: "https://example.com/2",
        content: nil,
        summary: "The European Union has approved comprehensive AI legislation.",
        extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-90000), createdAt: .now
    )
    entry.isRead = true
    context.insert(entry)

    return EntryRowView(entry: entry)
        .modelContainer(container)
        .frame(width: 380)
        .padding()
}
