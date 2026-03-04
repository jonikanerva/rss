import SwiftUI

struct EntryRowView: View {
    let entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title
            Text(entry.title ?? "Untitled")
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Metadata line: feed · date
            HStack(spacing: 4) {
                if let feedTitle = entry.feed?.title {
                    Text(feedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.quaternary)

                Text(entry.publishedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Summary excerpt
            if let summary = entry.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Category badges
            if !entry.categoryLabels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(entry.categoryLabels.prefix(3), id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.fill.quaternary, in: Capsule())
                    }
                    if entry.categoryLabels.count > 3 {
                        Text("+\(entry.categoryLabels.count - 3)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
