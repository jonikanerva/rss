import SwiftUI

struct OnboardingView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var username = ""
  @State
  private var password = ""
  @State
  private var isVerifying = false
  @State
  private var errorMessage: String?
  /// Scales the welcome icon alongside the rest of the typography when the
  /// user enables macOS *Larger Text*. Anchored to `.largeTitle` so it tracks
  /// the welcome title above it instead of growing on its own curve.
  @ScaledMetric(relativeTo: .largeTitle)
  private var iconSize: CGFloat = 50
  let onComplete: () -> Void

  var body: some View {
    // ScrollView keeps the welcome layout reachable at every Dynamic Type
    // size — at AX3 the scaled icon, `.largeTitle` welcome string, and
    // bordered text fields together exceed the default 380pt height and
    // would clip behind a fixed-height frame.
    ScrollView {
      VStack(spacing: 24) {
        Image(systemName: "newspaper.fill")
          .font(.system(size: iconSize))
          .foregroundStyle(.tint)

        Text("Welcome to Feeder")
          .font(fontSettings.articleTitle)
          .multilineTextAlignment(.center)

        Text("Connect your Feedbin account to get started.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        VStack(spacing: 12) {
          TextField("Email", text: $username)
            .textFieldStyle(.roundedBorder)
            .textContentType(.emailAddress)
            .accessibilityIdentifier("onboarding.email")

          SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .accessibilityIdentifier("onboarding.password")
        }
        .frame(maxWidth: 300)

        if let error = errorMessage {
          Text(error)
            .foregroundStyle(Color(nsColor: .systemRed))
            .font(fontSettings.caption)
            .multilineTextAlignment(.center)
        }

        Button {
          Task { await login() }
        } label: {
          if isVerifying {
            ProgressView()
              .scaleEffect(0.7)
          } else {
            Text("Connect")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(username.isEmpty || password.isEmpty || isVerifying)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("onboarding.connect")
      }
      .padding(40)
      .frame(maxWidth: .infinity)
    }
    // `.frame(width:height:)` would clip at AX3; `.frame(width:, minHeight:)`
    // is not a valid overload. Pin the width and let the ScrollView consume
    // any extra vertical space the window provides.
    .frame(width: 400)
    .frame(minHeight: 380)
  }

  private func login() async {
    isVerifying = true
    errorMessage = nil

    do {
      let saved = try await saveFeedbinCredentials(username: username, password: password)
      if saved {
        onComplete()
      } else {
        errorMessage = "Invalid credentials. Please try again."
      }
    } catch {
      errorMessage = error.localizedDescription
    }

    isVerifying = false
  }
}

// MARK: - Preview

#Preview("Onboarding - Default") {
  OnboardingView(onComplete: {})
    .environment(SyncEngine())
    .environment(AppFontSettings())
}

#Preview("Onboarding — Huge Text") {
  // `.dynamicTypeSize(_:)` propagates the environment value but does not
  // re-resolve system fonts on macOS, so a `.accessibility3` modifier
  // here would render identically to `.medium`. Inject the largest
  // `AppFontSettings` instead — that is the mechanism shipped code uses,
  // so the preview reflects what a user picking *Huge* actually sees.
  OnboardingView(onComplete: {})
    .environment(SyncEngine())
    .environment(AppFontSettings(textSize: .xxLarge))
}
