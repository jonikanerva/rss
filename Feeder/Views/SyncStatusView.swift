import SwiftData
import SwiftUI

/// Header shown above the sidebar — the app name plus lightweight sync /
/// classification progress strings. Isolated from the article list so
/// progress ticks don't force the list to re-render.
struct SyncStatusView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(\.openSettings)
  private var openSettings

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
        .font(fontSettings.sectionHeader)
        .foregroundStyle(.primary)
        .textCase(nil)

      if let fetchStatus = fetchStatusText {
        Text(fetchStatus)
          .font(fontSettings.status)
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
      if let classifyStatus = classifyStatusText {
        Text(classifyStatus)
          .font(fontSettings.status)
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
      if let error = syncEngine.lastError {
        errorBanner(error: error)
      }
    }
    .padding(.bottom, 4)
  }

  // MARK: - Error banner

  /// Inline secondary-styled banner shown beneath the sync status text.
  /// Calm/premium per `STACK.md § 11 → Readability`: no `.red`, no alert /
  /// sheet — orange-accented icon plus a contextual recovery button.
  private func errorBanner(error: SyncError) -> some View {
    HStack(spacing: 6) {
      Image(systemName: errorSymbol(for: error))
        .foregroundStyle(Color.orange)
      Text(errorLabel(for: error))
        .foregroundStyle(.secondary)
      Button(errorActionLabel(for: error)) {
        handleErrorAction(for: error)
      }
      .buttonStyle(.link)
      .disabled(syncEngine.isSyncing)
      .accessibilityIdentifier(errorActionAccessibilityID(for: error))
    }
    .font(fontSettings.status)
    .textCase(nil)
    .accessibilityIdentifier("sidebar.syncError")
  }

  private func errorSymbol(for error: SyncError) -> String {
    switch error {
    case .network: "wifi.slash"
    case .authFailed, .other: "exclamationmark.triangle"
    }
  }

  private func errorLabel(for error: SyncError) -> String {
    switch error {
    case .network, .other: "Sync failed"
    case .authFailed: "Sign in expired"
    }
  }

  private func errorActionLabel(for error: SyncError) -> String {
    switch error {
    case .network, .other: "Retry"
    case .authFailed: "Sign in again"
    }
  }

  private func errorActionAccessibilityID(for error: SyncError) -> String {
    switch error {
    case .network, .other: "sidebar.syncError.retry"
    case .authFailed: "sidebar.syncError.signIn"
    }
  }

  private func handleErrorAction(for error: SyncError) {
    switch error {
    case .network, .other:
      Task { await syncEngine.sync() }
    case .authFailed:
      openSettings()
    }
  }
}

// MARK: - Previews

/// Preview-only state seed describing each `SyncStatusView` variant the
/// STACK.md § 0 applicable-states checklist requires (idle / syncing /
/// success / error / offline). Tiny because it's the only thing
/// `syncStatusPreview` needs — no production code path reads it.
private enum SyncStatusPreviewState {
  case idle
  case syncing
  case success
  case errorNetwork
  case errorAuth
  case offline

  func apply(to engine: SyncEngine) {
    switch self {
    case .idle:
      engine.applyPreviewState()
    case .syncing:
      engine.applyPreviewState(isSyncing: true, fetchedCount: 42, totalToFetch: 120)
    case .success:
      engine.applyPreviewState(lastSyncDate: .now)
    case .errorNetwork:
      engine.applyPreviewState(
        lastSyncDate: .now.addingTimeInterval(-3600),
        lastError: .network("The Internet connection appears to be offline."))
    case .errorAuth:
      engine.applyPreviewState(
        lastSyncDate: .now.addingTimeInterval(-3600),
        lastError: .authFailed("Invalid Feedbin credentials"))
    case .offline:
      engine.applyPreviewState(
        lastError: .network("The Internet connection appears to be offline."))
    }
  }
}

#Preview("Idle") {
  syncStatusPreview(state: .idle)
}

#Preview("Syncing") {
  syncStatusPreview(state: .syncing)
}

#Preview("Success") {
  syncStatusPreview(state: .success)
}

#Preview("Error - Network") {
  syncStatusPreview(state: .errorNetwork)
}

#Preview("Error - Auth") {
  syncStatusPreview(state: .errorAuth)
}

#Preview("Offline") {
  syncStatusPreview(state: .offline)
}

@MainActor
private func syncStatusPreview(state: SyncStatusPreviewState) -> some View {
  let container = PreviewSupport.makeContainer()
  let syncEngine = SyncEngine()
  let classificationEngine = ClassificationEngine()
  state.apply(to: syncEngine)

  return SyncStatusView()
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 220)
    .padding()
}
