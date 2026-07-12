import Foundation

// MARK: - Day sectioning (pure transform over row snapshots)

/// Group already-sorted rows by calendar day, preserving order, returning the
/// section DTOs the article list renders. Moved from `DataWriter`'s
/// `groupEntriesByDay` (issue #148) with the element type switched from
/// `Entry` to `EntryRowDTO` — the transform is now pure and reusable from
/// tests without a container. The `Calendar.current` / `startOfDay`
/// day-bucketing and the `entryListSectionLabel` labels are UNCHANGED through
/// the move: grouping deliberately follows the user's local calendar, like
/// the "Today" / "Yesterday" labels it feeds (`STACK.md § 10` — the
/// pre-computed display-label divergence, § 14).
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
