import SwiftUI

struct EntryRowView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title ?? "Untitled")
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let feedTitle = entry.feed?.title {
                    Text(feedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(entry.publishedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
