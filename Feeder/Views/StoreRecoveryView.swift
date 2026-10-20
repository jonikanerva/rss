import AppKit
import SwiftUI

/// The launch state when the app store does not open. The store files stay in
/// place until the user chooses Start Over, and Start Over moves them to a
/// backup folder.
struct StoreRecoveryView: View {
  @Environment(AppFontSettings.self)
  private var fontSettings
  let failure: StoreFailure
  let startOver: () -> Void
  @ScaledMetric(relativeTo: .largeTitle)
  private var iconSize: CGFloat = 44

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "externaldrive.badge.xmark")
          .font(.system(size: iconSize))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        Text(title)
          .font(fontSettings.sectionHeader)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        Text(explanation)
          .font(fontSettings.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Text(detail)
          .font(fontSettings.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .accessibilityLabel("Error details: \(detail)")

        HStack(spacing: 12) {
          Button("Start Over", action: startOver)
            .accessibilityHint("Moves the current database to a backup folder and opens a new database.")
            .accessibilityIdentifier("storeRecovery.startOver")
          Button("Quit Feeder") { NSApp.terminate(nil) }
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Quits Feeder. The database stays unchanged.")
            .accessibilityIdentifier("storeRecovery.quit")
        }
        .font(fontSettings.body)
        .padding(.top, 8)
      }
      .padding(40)
      .frame(maxWidth: 520)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 480, minHeight: 360)
  }

  private var title: String {
    switch failure {
    case .openFailed: "Feeder could not open its database"
    case .startOverFailed: "Feeder could not start over"
    }
  }

  private var explanation: String {
    switch failure {
    case .openFailed:
      "Your folders, categories, and articles are still on this Mac. Quit Feeder to try another version, or start over with a new database. Start Over moves the current database to a backup folder next to it."
    case .startOverFailed:
      "Feeder deleted no database file. Quit Feeder, or try Start Over again."
    }
  }

  private var detail: String {
    switch failure {
    case .openFailed(let detail), .startOverFailed(let detail): detail
    }
  }
}

// MARK: - Preview

#Preview("Store Recovery — Open Failed") {
  StoreRecoveryView(failure: .openFailed(detail: "The file “Feeder.store” could not be opened."), startOver: {})
    .environment(AppFontSettings())
}

#Preview("Store Recovery — Start Over Failed") {
  StoreRecoveryView(
    failure: .startOverFailed(
      detail:
        "Feeder could not move Feeder.store-wal to the backup folder. The database files are in their original place."
    ),
    startOver: {}
  )
  .environment(AppFontSettings())
}

#Preview("Store Recovery — Huge Text") {
  // `.dynamicTypeSize(_:)` would render identically to `.medium` on macOS, so
  // the preview injects the font settings the shipped code uses.
  StoreRecoveryView(failure: .openFailed(detail: "The file “Feeder.store” could not be opened."), startOver: {})
    .environment(AppFontSettings(textSize: .xxLarge))
}
