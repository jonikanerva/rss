import SwiftUI

/// Classification provider selection and OpenAI API key management.
struct ClassificationSettingsView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine

  @State
  private var selectedProvider: ClassificationProviderKind = ClassificationProviderKind.current
  @State
  private var hasStoredKey: Bool = KeychainHelper.load(key: KeychainHelper.openAIAPIKeychainKey) != nil
  @State
  private var showReclassifyAlert = false
  @State
  private var showAPIKeyEditor = false
  @State
  private var hadKeyBeforeEdit = false

  var body: some View {
    Form {
      Section("Classification Provider") {
        Picker("Provider", selection: $selectedProvider) {
          ForEach(ClassificationProviderKind.allCases, id: \.self) { kind in
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                Text(kind.subtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: kind.iconName)
            }
            .tag(kind)
          }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }

      if selectedProvider == .openAI {
        Section("OpenAI API Key") {
          HStack {
            if hasStoredKey {
              Label("API key is saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
              Label("No API key configured", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
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
    .onChange(of: selectedProvider) { oldValue, newValue in
      guard oldValue != newValue else { return }
      ClassificationProviderKind.persist(newValue)
      // Only prompt reclassify when switching to a provider that's ready to use
      if newValue == .appleFM || hasStoredKey {
        showReclassifyAlert = true
      }
    }
    .onChange(of: showAPIKeyEditor) { _, isPresented in
      if isPresented {
        hadKeyBeforeEdit = hasStoredKey
      } else if hasStoredKey, !hadKeyBeforeEdit, selectedProvider == .openAI {
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
}

// MARK: - API Key Edit Sheet

private struct APIKeyEditSheet: View {
  @Binding
  var hasStoredKey: Bool

  @Environment(\.dismiss)
  private var dismiss
  @State
  private var editKey: String = ""
  @State
  private var errorMessage: String?

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
            .foregroundStyle(Color(nsColor: .systemGreen))
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(FontTheme.caption)
            .foregroundStyle(Color(nsColor: .systemRed))
        }
      }
      .padding()

      Divider()
      HStack {
        if hasStoredKey {
          Button("Remove Key", role: .destructive) {
            performRemove()
          }
        }

        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          performSave()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(editKey.isEmpty)
      }
      .padding()
    }
    .frame(width: 400)
  }

  // Commit only what the keychain actually accepted: errors keep the sheet
  // open with an inline message so the parent view never shows "A key is
  // currently saved" for a write that failed.
  private func performSave() {
    do {
      try KeychainHelper.save(key: KeychainHelper.openAIAPIKeychainKey, value: editKey)
      hasStoredKey = true
      dismiss()
    } catch {
      errorMessage = "Couldn't save API key to Keychain: \(String(describing: error))"
    }
  }

  private func performRemove() {
    do {
      try KeychainHelper.delete(key: KeychainHelper.openAIAPIKeychainKey)
      hasStoredKey = false
      dismiss()
    } catch {
      errorMessage = "Couldn't remove API key from Keychain: \(String(describing: error))"
    }
  }
}
