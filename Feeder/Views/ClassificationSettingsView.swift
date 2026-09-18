import SwiftData
import SwiftUI

/// Classification provider selection and OpenAI API key management.
struct ClassificationSettingsView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings

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
  @State
  private var modelSelection: String = OpenAIModelSetting.current()
  @State
  private var modelListState: ModelListState = .needsKey
  @State
  private var reclassifyTrigger: ReclassifyTrigger = .provider

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
        Section("OpenAI") {
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

          OpenAIModelPickerRow(selection: $modelSelection, state: modelListState)

          // The outcome of the most recent batch attempt. The poll refreshes or
          // clears it within seconds of a settings change, and that poll is the
          // save-time verification, so nothing clears it eagerly.
          if let abort = classificationEngine.lastAbort {
            Label(abort.displayLabel, systemImage: abort.symbolName)
              .font(fontSettings.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showAPIKeyEditor) {
      APIKeyEditSheet(hasStoredKey: $hasStoredKey)
    }
    .task(id: modelFetchKey) {
      await refreshModelList()
    }
    .onChange(of: selectedProvider) { _, newValue in
      // `onChange` fires only on an actual change, so no diff guard is needed.
      ClassificationProviderKind.persist(newValue)
      // Prompt for a reclassify only when the new provider is ready to use.
      if newValue == .appleFM || hasStoredKey {
        reclassifyTrigger = .provider
        showReclassifyAlert = true
      }
    }
    .onChange(of: modelSelection) { _, newValue in
      // The only call site that persists the model: the key is written on an
      // explicit user pick alone, so a user who never picked keeps tracking the
      // app default. Nothing may write the selection programmatically — that
      // fires this handler and pins every user to the current value.
      OpenAIModelSetting.persist(newValue)
      // The same readiness gate as the provider switch: a keyless model change
      // must not offer a reclassify that would run on the other provider.
      if hasStoredKey {
        reclassifyTrigger = .model
        showReclassifyAlert = true
      }
    }
    .onChange(of: showAPIKeyEditor) { _, isPresented in
      if isPresented {
        hadKeyBeforeEdit = hasStoredKey
      } else if hasStoredKey, !hadKeyBeforeEdit, selectedProvider == .openAI {
        // Prompt only when a key was added, never when one was removed.
        reclassifyTrigger = .provider
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
      switch reclassifyTrigger {
      case .provider:
        Text("Would you like to reclassify all articles with the new provider?")
      case .model:
        Text("Would you like to reclassify all articles with the new model?")
      }
    }
  }

  /// Drives the fetch task: it re-fires when the provider or the stored-key
  /// state changes. This view exists only while Settings is open, so the fetch
  /// never runs at launch or from background sync.
  private var modelFetchKey: String {
    "\(selectedProvider.rawValue)|\(hasStoredKey)"
  }

  private func refreshModelList() async {
    guard selectedProvider == .openAI else { return }
    guard hasStoredKey,
      let apiKey = KeychainHelper.load(key: KeychainHelper.openAIAPIKeychainKey),
      !apiKey.isEmpty
    else {
      modelListState = .needsKey
      return
    }

    modelListState = .loading
    let outcome: Result<[OpenAIModel], OpenAIModelsError>
    do throws(OpenAIModelsError) {
      outcome = .success(try await OpenAIModelsClient().fetchModels(apiKey: apiKey))
    } catch {
      outcome = .failure(error)
    }
    // The task owns cancellation, and a cancelled fetch surfaces as a network
    // failure. Do not flash a failure the view itself abandoned.
    guard !Task.isCancelled else { return }
    modelListState = resolveModelListState(outcome: outcome)
  }
}

/// Which settings change is offering the reclassify prompt, which selects the
/// single alert's message copy.
private enum ReclassifyTrigger {
  case provider
  case model
}

// MARK: - OpenAI model picker row

/// The model picker and its quiet status line, extracted so the preview matrix
/// exercises every list state. The picker stays enabled with at least the floor
/// options, so the surface never dead-ends, and uses the menu style because the
/// loaded list passes the option-count threshold (`STACK.md § 11`).
private struct OpenAIModelPickerRow: View {
  @Binding
  var selection: String
  let state: ModelListState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Model", selection: $selection) {
        ForEach(
          pickerOptions(
            for: state,
            selection: selection,
            defaultModel: OpenAIModelSetting.defaultModel
          ),
          id: \.self
        ) { modelID in
          Text(modelID).tag(modelID)
        }
      }
      .pickerStyle(.menu)

      statusLine
    }
  }

  @ViewBuilder
  private var statusLine: some View {
    switch state {
    case .needsKey:
      captionText("Add an API key to load available models.")
    case .loading:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Loading available models…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .loaded:
      EmptyView()
    case .empty:
      captionText("No compatible models found for this key.")
    case .failed(let reason):
      captionText(reason)
    }
  }

  private func captionText(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

// MARK: - API Key Edit Sheet

private struct APIKeyEditSheet: View {
  @Binding
  var hasStoredKey: Bool

  @Environment(\.dismiss)
  private var dismiss
  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var editKey: String = ""
  @State
  private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("OpenAI API Key")
          .font(fontSettings.headline)
        Spacer()
      }
      .padding()
      Divider()

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("API Key")
            .font(fontSettings.caption)
            .foregroundStyle(.secondary)
          SecureField(hasStoredKey ? "Enter new key to replace" : "sk-...", text: $editKey)
            .textFieldStyle(.roundedBorder)
        }

        if hasStoredKey {
          Label("A key is currently saved", systemImage: "checkmark.circle.fill")
            .font(fontSettings.caption)
            .foregroundStyle(Color(nsColor: .systemGreen))
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(fontSettings.caption)
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

  // Commit only what the keychain accepted. An error keeps the sheet open with
  // an inline message, so the parent never claims a key is saved after a failed
  // write.
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

// MARK: - Preview

#Preview("Classification Settings - Success") {
  ClassificationSettingsView()
    .environment(SyncEngine())
    .environment(ClassificationEngine())
    .environment(AppFontSettings())
    .modelContainer(PreviewSupport.makeContainer())
    .frame(width: 480, height: 320)
}

#Preview("Classification Settings - Batch aborted") {
  let engine = ClassificationEngine()
  engine.applyPreviewState(lastAbort: .modelRejected)
  return ClassificationSettingsView()
    .environment(SyncEngine())
    .environment(engine)
    .environment(AppFontSettings())
    .modelContainer(PreviewSupport.makeContainer())
    .frame(width: 480, height: 360)
}

// Model-picker state matrix. The large case sits above the option-count
// threshold in `STACK.md § 11` on purpose.

#Preview("Model Picker - Loaded (Large N)") {
  @Previewable
  @State
  var selection = OpenAIModelSetting.defaultModel
  Form {
    Section("OpenAI") {
      OpenAIModelPickerRow(
        selection: $selection,
        state: .loaded(
          ["gpt-5.6-luna", "gpt-5.4-nano"] + (1...23).map { "gpt-preview-model-\($0)" }
        )
      )
    }
  }
  .formStyle(.grouped)
  .frame(width: 480, height: 200)
}

#Preview("Model Picker - Needs Key") {
  @Previewable
  @State
  var selection = OpenAIModelSetting.defaultModel
  Form {
    Section("OpenAI") {
      OpenAIModelPickerRow(selection: $selection, state: .needsKey)
    }
  }
  .formStyle(.grouped)
  .frame(width: 480, height: 200)
}

#Preview("Model Picker - Loading") {
  @Previewable
  @State
  var selection = OpenAIModelSetting.defaultModel
  Form {
    Section("OpenAI") {
      OpenAIModelPickerRow(selection: $selection, state: .loading)
    }
  }
  .formStyle(.grouped)
  .frame(width: 480, height: 200)
}

#Preview("Model Picker - Empty") {
  @Previewable
  @State
  var selection = OpenAIModelSetting.defaultModel
  Form {
    Section("OpenAI") {
      OpenAIModelPickerRow(selection: $selection, state: .empty)
    }
  }
  .formStyle(.grouped)
  .frame(width: 480, height: 200)
}

#Preview("Model Picker - Failed") {
  @Previewable
  @State
  var selection = OpenAIModelSetting.defaultModel
  Form {
    Section("OpenAI") {
      OpenAIModelPickerRow(selection: $selection, state: .failed(reason: "API key was rejected."))
    }
  }
  .formStyle(.grouped)
  .frame(width: 480, height: 200)
}
