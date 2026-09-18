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
  /// Scales the welcome icon with the rest of the typography. Anchored to the
  /// title's text style, so it tracks the title instead of growing on its own
  /// curve.
  @ScaledMetric(relativeTo: .largeTitle)
  private var iconSize: CGFloat = 50
  let onComplete: () -> Void

  var body: some View {
    // The scroll view keeps the layout reachable at every Dynamic Type size: at
    // the largest sizes the icon, title and fields exceed the default height and
    // a fixed-height frame would clip them.
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
    // A fixed height clips at the largest text sizes, and there is no
    // width-and-minimum-height overload. Pin the width and let the scroll view
    // take the extra vertical space.
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
  // `.dynamicTypeSize(_:)` would render identically to `.medium` on macOS, so
  // the preview injects the font settings the shipped code uses.
  OnboardingView(onComplete: {})
    .environment(SyncEngine())
    .environment(AppFontSettings(textSize: .xxLarge))
}
