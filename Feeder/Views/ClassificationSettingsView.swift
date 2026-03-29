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

  var body: some View {
    Form {
      Section("Classification Provider") {
        VStack(alignment: .leading, spacing: 12) {
          providerRow(
            tag: "apple_fm",
            icon: "apple.logo",
            title: "Apple Foundation Models",
            subtitle: "Free \u{00B7} On-device \u{00B7} Private"
          )

          Divider()

          providerRow(
            tag: "openai",
            icon: "cloud",
            title: "OpenAI GPT-5.4-nano",
            subtitle: "Requires API key \u{00B7} Cloud-based"
          )
        }
        .padding(.vertical, 4)
      }

      if selectedProvider == "openai" {
        Section("OpenAI API Key") {
          if hasStoredKey {
            HStack {
              Label("API key is saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

              Spacer()

              Button("Clear Key") {
                KeychainHelper.delete(key: "openai_api_key")
                apiKeyInput = ""
                hasStoredKey = false
              }
              .controlSize(.small)
            }

            SecureField("Enter new key to replace", text: $apiKeyInput)
              .textFieldStyle(.roundedBorder)
              .onSubmit {
                saveAPIKey()
              }

            if !apiKeyInput.isEmpty {
              Button("Update Key") {
                saveAPIKey()
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
            }
          } else {
            Label("No API key configured", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)

            SecureField("sk-...", text: $apiKeyInput)
              .textFieldStyle(.roundedBorder)
              .onSubmit {
                saveAPIKey()
              }

            if !apiKeyInput.isEmpty {
              Button("Save Key") {
                saveAPIKey()
              }
              .buttonStyle(.borderedProminent)
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

  // MARK: - Provider row

  private func providerRow(tag: String, icon: String, title: String, subtitle: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: selectedProvider == tag ? "circle.inset.filled" : "circle")
        .foregroundStyle(selectedProvider == tag ? Color.accentColor : .secondary)
        .font(.title3)

      Image(systemName: icon)
        .frame(width: 20)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      guard selectedProvider != tag else { return }
      selectedProvider = tag
      UserDefaults.standard.set(tag, forKey: "classification_provider")
      // Only prompt reclassify when switching to a provider that's ready to use
      if tag == "apple_fm" || hasStoredKey {
        showReclassifyAlert = true
      }
    }
  }

  private func saveAPIKey() {
    guard !apiKeyInput.isEmpty else { return }
    KeychainHelper.save(key: "openai_api_key", value: apiKeyInput)
    hasStoredKey = true
    apiKeyInput = ""
  }
}
