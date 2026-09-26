import SwiftData
import SwiftUI

/// Header above the sidebar: the app name plus the sync and classification
/// progress strings. Isolated from the article list, so a progress tick never
/// re-renders the list.
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
      if let abort = classificationEngine.lastAbort {
        classificationBanner(abort: abort)
      }
    }
    .padding(.bottom, 4)
  }

  // MARK: - Error banner

  /// Inline banner beneath the sync status text. Calm per
  /// `STACK.md § 11 → Readability`: no red, no alert, no sheet — an accented
  /// icon and a contextual recovery button.
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

  // MARK: - Classification banner

  /// Inline banner for the most recent classification batch outcome, in the
  /// same shape as `errorBanner`. It offers Settings only for a cause the user
  /// can fix there; a self-healing cause gets no button. The words carry the
  /// meaning, never colour alone. With no abort the line disappears.
  private func classificationBanner(abort: ClassificationAbortReason) -> some View {
    HStack(spacing: 6) {
      Image(systemName: abort.symbolName)
        .foregroundStyle(Color.orange)
      Text(abort.displayLabel(reportedBy: classificationEngine.lastAbortProvider))
        .foregroundStyle(.secondary)
      if abort.offersSettings {
        Button("Open Settings") {
          openSettings()
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("sidebar.classificationError.openSettings")
      }
    }
    .font(fontSettings.status)
    .textCase(nil)
    .accessibilityIdentifier("sidebar.classificationError")
  }
}

// MARK: - Previews

/// Preview-only state seed covering each `SyncStatusView` variant the
/// applicable-states checklist requires (`STACK.md § 0`), plus the
/// classification-progress cases. Each case seeds both engines, so the fetch
/// and categorize rows can appear together. No production path reads it.
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
  case abortedModel
  case abortedNeedsKey
  case abortedKeyUnreadable
  case abortedOffline
  case abortedRateLimited
  case abortedQuotaExhausted
  case abortedQuotaExhaustedVercel
  case abortedWhileSyncing

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
      // The denominator has grown past the first snapshot's value while sync
      // kept persisting, instead of staying pinned to it.
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 150, totalToClassify: 1000)
    case .largeNumbers:
      // Threshold check: the widest realistic strings at the narrow sidebar
      // width must not truncate (`STACK.md § 11`).
      sync.applyPreviewState(isSyncing: true, fetchedCount: 1234, totalToFetch: 12345)
      classification.applyPreviewState(
        isClassifying: true, classifiedCount: 999, totalToClassify: 9999)
    case .syncingNoTotal:
      // A zero total makes the fetch row fall back to its indeterminate copy.
      sync.applyPreviewState(isSyncing: true, fetchedCount: 0, totalToFetch: 0)
    case .abortedModel:
      // Classification banner with the "Open Settings" recovery button.
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .modelRejected)
    case .abortedNeedsKey:
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .needsKey, provider: .openAI)
    case .abortedKeyUnreadable:
      // Threshold check for the Keychain read copy at the largest text size (`STACK.md § 11`).
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .keyUnreadable, provider: .vercel)
    case .abortedOffline:
      // Self-healing cause → no button; exercises the wifi.slash symbol.
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .offline)
    case .abortedRateLimited:
      // Self-healing cause → no button; a rate limit from any provider shows
      // this service-limit label.
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .rateLimited)
    case .abortedQuotaExhausted:
      // Settings-fixable cause → "Open Settings". Threshold check: its preview
      // runs at the largest text size in the narrow frame, and the label and
      // the button must not truncate (`STACK.md § 11`).
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .quotaExhausted, provider: .openAI)
    case .abortedQuotaExhaustedVercel:
      // Threshold check for the Vercel quota copy at the largest text size (`STACK.md § 11`).
      sync.applyPreviewState(lastSyncDate: .now)
      classification.applyPreviewState(lastAbort: .quotaExhausted, provider: .vercel)
    case .abortedWhileSyncing:
      // Both banners stacked at the narrow frame must not truncate
      // (`STACK.md § 11`).
      sync.applyPreviewState(
        lastSyncDate: .now.addingTimeInterval(-3600),
        lastError: .network("The Internet connection appears to be offline."))
      classification.applyPreviewState(lastAbort: .providerUnavailable)
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

#Preview("Aborted - Model rejected") {
  syncStatusPreview(state: .abortedModel)
}

#Preview("Aborted - Needs key") {
  syncStatusPreview(state: .abortedNeedsKey)
}

#Preview("Aborted - Key unreadable") {
  syncStatusPreview(state: .abortedKeyUnreadable, textSize: .xxLarge)
}

#Preview("Aborted - Service limit") {
  syncStatusPreview(state: .abortedRateLimited)
}

#Preview("Aborted - Quota") {
  syncStatusPreview(state: .abortedQuotaExhausted, textSize: .xxLarge)
}

#Preview("Aborted - Quota (Vercel)") {
  syncStatusPreview(state: .abortedQuotaExhaustedVercel, textSize: .xxLarge)
}

#Preview("Aborted - Offline") {
  syncStatusPreview(state: .abortedOffline)
}

#Preview("Aborted + Sync error") {
  syncStatusPreview(state: .abortedWhileSyncing)
}

@MainActor
private func syncStatusPreview(state: SyncStatusPreviewState, textSize: AppTextSize? = nil) -> some View {
  let container = PreviewSupport.makeContainer()
  let syncEngine = SyncEngine()
  let classificationEngine = ClassificationEngine()
  state.apply(toSync: syncEngine, classification: classificationEngine)

  return SyncStatusView()
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(textSize.map { AppFontSettings(textSize: $0) } ?? AppFontSettings())
    .modelContainer(container)
    .frame(width: 220)
    .padding()
}
