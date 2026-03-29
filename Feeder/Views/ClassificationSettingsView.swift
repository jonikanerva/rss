import SwiftUI

/// Classification provider selection and OpenAI API key management.
struct ClassificationSettingsView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine

  @State
  private var selectedProvider: String = UserDefaults.standard.string(forKey: "classification_provider") ?? "apple_fm"
  @State
  private var apiKeyInput: String = ""
  @State
  private var hasStoredKey: Bool = KeychainHelper.load(key: "openai_api_key") != nil
  @State
  private var showReclassifyAlert = false
  @State
  private var previousProvider: String = ""

  var body: some View {
    Form {
      Section("Classification Provider") {
        Picker("Provider", selection: $selectedProvider) {
          Label {
            VStack(alignment: .leading) {
              Text("Apple Foundation Models")
              Text("Free \u{00B7} On-device \u{00B7} Private")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "apple.logo")
          }
          .tag("apple_fm")

          Label {
            VStack(alignment: .leading) {
              Text("OpenAI GPT-5.4-nano")
              Text("Requires API key \u{00B7} Cloud-based")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "cloud")
          }
          .tag("openai")
        }
        .pickerStyle(.radioGroup)
        .onChange(of: selectedProvider) { oldValue, newValue in
          previousProvider = oldValue
          UserDefaults.standard.set(newValue, forKey: "classification_provider")
          showReclassifyAlert = true
        }
      }

      if selectedProvider == "openai" {
        Section("OpenAI API Key") {
          SecureField("sk-...", text: $apiKeyInput)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              saveAPIKey()
            }

          HStack {
            if hasStoredKey {
              Label("Key saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            } else {
              Label("No key set", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            }

            Spacer()

            if !apiKeyInput.isEmpty {
              Button("Save") {
                saveAPIKey()
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
            }

            if hasStoredKey {
              Button("Clear") {
                KeychainHelper.delete(key: "openai_api_key")
                apiKeyInput = ""
                hasStoredKey = false
              }
              .controlSize(.small)
            }
          }
        }
      }

      Section {
        Button("Reclassify All Articles") {
          Task {
            if let writer = syncEngine.writer {
              await classificationEngine.reclassifyAll(writer: writer)
            }
          }
        }
        .disabled(classificationEngine.isClassifying)

        if classificationEngine.isClassifying {
          HStack {
            ProgressView()
              .scaleEffect(0.7)
            Text(classificationEngine.progress)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .alert("Reclassify Articles?", isPresented: $showReclassifyAlert) {
      Button("Reclassify") {
        Task {
          if let writer = syncEngine.writer {
            await classificationEngine.reclassifyAll(writer: writer)
          }
        }
      }
      Button("Later", role: .cancel) {}
    } message: {
      Text("Would you like to reclassify all articles with the new provider?")
    }
  }

  private func saveAPIKey() {
    guard !apiKeyInput.isEmpty else { return }
    KeychainHelper.save(key: "openai_api_key", value: apiKeyInput)
    hasStoredKey = true
    apiKeyInput = ""
  }
}
