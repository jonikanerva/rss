import Foundation

// MARK: - Day sectioning (pure transform over row snapshots)

/// Group already-sorted rows by calendar day, preserving order. Grouping
/// follows the user's local calendar on purpose, like the day labels it feeds
/// (`STACK.md § 10` and § 14).
nonisolated func groupRowsByDay(_ rows: [EntryRowDTO]) -> [EntryListSection] {
  let calendar = Calendar.current
  var sections: [EntryListSection] = []
  var currentDay: Date?
  var currentRows: [EntryRowDTO] = []

  for row in rows {
    let day = calendar.startOfDay(for: row.publishedAt)
    if day != currentDay {
      if let prevDay = currentDay, !currentRows.isEmpty {
        sections.append(
          EntryListSection(id: prevDay, label: entryListSectionLabel(for: prevDay), rows: currentRows)
        )
      }
      currentDay = day
      currentRows = [row]
    } else {
      currentRows.append(row)
    }
  }
  if let lastDay = currentDay, !currentRows.isEmpty {
    sections.append(
      EntryListSection(id: lastDay, label: entryListSectionLabel(for: lastDay), rows: currentRows)
    )
  }
  return sections
}
