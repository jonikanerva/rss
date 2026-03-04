import SwiftUI

struct SettingsView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @State private var username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
    @State private var password = KeychainHelper.load(key: "feedbin_password") ?? ""
    @State private var isSaving = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Feedbin Account") {
                TextField("Email", text: $username)
                    .textContentType(.emailAddress)

                SecureField("Password", text: $password)
                    .textContentType(.password)

                HStack {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSaving)

                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    if let status = statusMessage {
                        Text(status)
                            .foregroundStyle(status.contains("Error") ? .red : .green)
                            .font(.caption)
                    }
                }
            }

            Section("Sync") {
                LabeledContent("Last sync") {
                    if let date = syncEngine.lastSyncDate {
                        Text(date, style: .relative)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Status") {
                    Text(syncEngine.syncProgress)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 300)
        .navigationTitle("Settings")
    }

    private func save() async {
        isSaving = true
        statusMessage = nil

        let client = FeedbinClient(username: username, password: password)
        do {
            let valid = try await client.verifyCredentials()
            if valid {
                UserDefaults.standard.set(username, forKey: "feedbin_username")
                KeychainHelper.save(key: "feedbin_password", value: password)
                statusMessage = "Saved ✓"
            } else {
                statusMessage = "Error: Invalid credentials"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
