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
  private var hasStoredKey: Bool = KeychainHelper.load(key: "openai_api_key") != nil
  @State
  private var showReclassifyAlert = false
  @State
  private var showAPIKeyEditor = false
  @State
  private var hadKeyBeforeEdit = false

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
          HStack {
            if hasStoredKey {
              Label("API key is saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            } else {
              Label("No API key configured", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }

            Spacer()

            Button(hasStoredKey ? "Edit" : "Add Key") {
              showAPIKeyEditor = true
            }
            .controlSize(.small)
          }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showAPIKeyEditor) {
      APIKeyEditSheet(hasStoredKey: $hasStoredKey)
    }
    .onChange(of: showAPIKeyEditor) { _, isPresented in
      if isPresented {
        hadKeyBeforeEdit = hasStoredKey
      } else if hasStoredKey, !hadKeyBeforeEdit, selectedProvider == "openai" {
        // Prompt only when a key was added (not removed)
        showReclassifyAlert = true
      }
    }
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
}

// MARK: - API Key Edit Sheet

private struct APIKeyEditSheet: View {
  @Binding
  var hasStoredKey: Bool

  @Environment(\.dismiss)
  private var dismiss
  @State
  private var editKey: String = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("OpenAI API Key")
          .font(FontTheme.headline)
        Spacer()
      }
      .padding()
      Divider()

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("API Key")
            .font(FontTheme.caption)
            .foregroundStyle(.secondary)
          SecureField(hasStoredKey ? "Enter new key to replace" : "sk-...", text: $editKey)
            .textFieldStyle(.roundedBorder)
        }

        if hasStoredKey {
          Label("A key is currently saved", systemImage: "checkmark.circle.fill")
            .font(FontTheme.caption)
            .foregroundStyle(.green)
        }
      }
      .padding()

      Divider()
      HStack {
        if hasStoredKey {
          Button("Remove Key", role: .destructive) {
            KeychainHelper.delete(key: "openai_api_key")
            hasStoredKey = false
            dismiss()
          }
        }

        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          KeychainHelper.save(key: "openai_api_key", value: editKey)
          hasStoredKey = true
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(editKey.isEmpty)
      }
      .padding()
    }
    .frame(width: 400)
  }
}
