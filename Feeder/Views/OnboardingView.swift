import SwiftUI

struct OnboardingView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @State
  private var username = ""
  @State
  private var password = ""
  @State
  private var isVerifying = false
  @State
  private var errorMessage: String?
  let onComplete: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "newspaper.fill")
        .font(.system(size: FontTheme.iconSize))
        .foregroundStyle(.tint)

      Text("Welcome to Feeder")
        .font(FontTheme.title)

      Text("Connect your Feedbin account to get started.")
        .foregroundStyle(.secondary)

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
          .foregroundStyle(.red)
          .font(FontTheme.caption)
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
    .frame(width: 400, height: 380)
  }

  private func login() async {
    isVerifying = true
    errorMessage = nil

    let client = FeedbinClient(username: username, password: password)
    do {
      let valid = try await client.verifyCredentials()
      if valid {
        UserDefaults.standard.set(username, forKey: "feedbin_username")
        KeychainHelper.save(key: "feedbin_password", value: password)
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
}
