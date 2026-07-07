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
/// STACK.md § 0 applicable-states checklist requires, plus the
/// classification-progress cases issue #124 exercises (classifying-only,
/// sync + classify together, a mid-drain grown denominator, and the
/// large-number layout at the 220 pt sidebar width). Each case seeds both
/// engines so the "Fetching" and "Categorizing" rows can be shown together —
/// the seam previously only touched `SyncEngine`, leaving the classify row
/// with no preview coverage at all. No production code path reads this.
private enum SyncStatusPreviewState {
  case idle
  case syncing
  case success
  case errorNetwork
  case errorAuth
  case offline
  case classifying
  case syncingAndClassifying
  case midDrainGrownDenominator
  case largeNumbers
  case syncingNoTotal

  func apply(toSync sync: SyncEngine, classification: ClassificationEngine) {
    switch self {
    case .idle:
      sync.applyPreviewState()
    case .syncing:
      sync.applyPreviewState(isSyncing: true, fetchedCount: 42, totalToFetch: 120)
    case .success:
      sync.applyPreviewState(lastSyncDate: .now)
    case .errorNetwork:
      sync.applyPreviewState(
        lastSyncDate: .now.addingTimeInterval(-3600),
        lastError: .network("The Internet connection appears to be offline."))
    case .errorAuth:
      sync.applyPreviewState(
        lastSyncDate: .now.addingTimeInterval(-3600),
        lastError: .authFailed("Invalid Feedbin credentials"))
    case .offline:
      sync.applyPreviewState(
        lastError: .network("The Internet connection appears to be offline."))
    case .classifying:
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 12, totalToClassify: 200)
    case .syncingAndClassifying:
      sync.applyPreviewState(isSyncing: true, fetchedCount: 480, totalToFetch: 1000)
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 120, totalToClassify: 480)
    case .midDrainGrownDenominator:
      // The denominator has grown past the first snapshot's value as sync kept
      // persisting — issue #124's core case (150/1000, not stuck at 150/200).
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 150, totalToClassify: 1000)
    case .largeNumbers:
      // Threshold layout check: widest realistic strings at the 220 pt sidebar
      // width must not truncate (STACK.md § 11 — exercise at the threshold).
      sync.applyPreviewState(isSyncing: true, fetchedCount: 1234, totalToFetch: 12345)
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 999, totalToClassify: 9999)
    case .syncingNoTotal:
      // totalToFetch == 0 → the fetch row falls back to "Syncing...".
      sync.applyPreviewState(isSyncing: true, fetchedCount: 0, totalToFetch: 0)
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

#Preview("Classifying") {
  syncStatusPreview(state: .classifying)
}

#Preview("Syncing + Classifying") {
  syncStatusPreview(state: .syncingAndClassifying)
}

#Preview("Mid-drain grown denominator") {
  syncStatusPreview(state: .midDrainGrownDenominator)
}

#Preview("Large numbers") {
  syncStatusPreview(state: .largeNumbers)
}

#Preview("Syncing - no total") {
  syncStatusPreview(state: .syncingNoTotal)
}

@MainActor
private func syncStatusPreview(state: SyncStatusPreviewState) -> some View {
  let container = PreviewSupport.makeContainer()
  let syncEngine = SyncEngine()
  let classificationEngine = ClassificationEngine()
  state.apply(toSync: syncEngine, classification: classificationEngine)

  return SyncStatusView()
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 220)
    .padding()
}
