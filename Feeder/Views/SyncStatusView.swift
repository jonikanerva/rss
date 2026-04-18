import SwiftUI

/// Header shown above the sidebar — the app name plus lightweight sync /
/// classification progress strings. Isolated from the article list so
/// progress ticks don't force the list to re-render.
struct SyncStatusView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine

  private var lastSyncText: String? {
    guard let date = syncEngine.lastSyncDate else { return nil }
    let calendar = Calendar.current
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    if calendar.isDateInToday(date) {
      return "Synced today \(time)"
    } else if calendar.isDateInYesterday(date) {
      return "Synced yesterday \(time)"
    } else {
      return "Synced \(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
  }

  private var fetchStatusText: String? {
    if syncEngine.isSyncing {
      let n = syncEngine.fetchedCount
      let x = syncEngine.totalToFetch
      return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
    }
    return lastSyncText
  }

  private var classifyStatusText: String? {
    guard classificationEngine.isClassifying else { return nil }
    let n = classificationEngine.classifiedCount
    let x = classificationEngine.totalToClassify
    return x > 0 ? "Categorizing \(n)/\(x)" : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("News")
        .font(.system(size: FontTheme.sectionHeaderSize, weight: .bold))
        .foregroundStyle(.primary)
        .textCase(nil)

      if let fetchStatus = fetchStatusText {
        Text(fetchStatus)
          .font(.system(size: FontTheme.statusSize))
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
      if let classifyStatus = classifyStatusText {
        Text(classifyStatus)
          .font(.system(size: FontTheme.statusSize))
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
    }
    .padding(.bottom, 4)
  }
}
