import SwiftData
import SwiftUI

struct ClassificationSettingsView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var settings: ClassificationSettingsModel
  @State
  private var keyEditor: ClassificationProviderKind?
  @State
  private var pendingReclassification: ClassificationProviderKind?
  @State
  private var pendingProviderSelection: ClassificationProviderKind?
  @State
  private var reclassifyTarget: String?
  @State
  private var modelSelection: String = OpenAIModelSetting.current()
  @State
  private var modelListState: ModelListState = .needsKey

  init(settings: ClassificationSettingsModel = ClassificationSettingsModel()) {
    _settings = State(initialValue: settings)
  }

  var body: some View {
    Form {
      Section("Classification Provider") {
        Picker("Provider", selection: Binding(get: { settings.provider }, set: selectProvider)) {
          ForEach(ClassificationProviderKind.allCases, id: \.self) { kind in
            Text(kind.displayName)
              .accessibilityIdentifier("classification.provider.\(kind.rawValue)")
              .tag(kind)
          }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        Text(settings.provider.subtitle).font(fontSettings.caption).foregroundStyle(.secondary)
      }
      if settings.provider != .appleFM {
        Section(settings.provider.displayName) {
          HStack {
            Label(
              settings.isLoadingKey ? "Checking API key…" : (settings.hasStoredKey ? "API key is saved" : "No API key configured"),
              systemImage: settings.hasStoredKey ? "checkmark.circle" : "key")
            Spacer()
            Button(settings.hasStoredKey ? "Edit" : "Add Key") { keyEditor = settings.provider }
              .controlSize(.small)
              .accessibilityIdentifier("classification.key.edit")
              .disabled(settings.isLoadingKey)
          }
          if settings.provider == .openAI {
            OpenAIModelPickerRow(selection: Binding(get: { modelSelection }, set: selectModel), state: modelListState)
          } else {
            LabeledContent("Model", value: "JEV (Typesafe)")
            Text("Article titles, text, and category definitions are sent to Vercel AI Gateway and Typesafe for classification.")
              .font(fontSettings.caption)
              .foregroundStyle(.secondary)
          }
          if let abort = classificationEngine.lastAbort, classificationEngine.lastAbortProvider == settings.provider {
            HStack {
              Label(abort.displayLabel, systemImage: abort.symbolName)
                .font(fontSettings.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Retry") {
                Task {
                  if let writer = syncEngine.writer { await classificationEngine.classifyUnclassified(writer: writer) }
                }
              }
              .disabled(classificationEngine.isClassifying || !settings.hasStoredKey)
              .accessibilityIdentifier("classification.retry")
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .sheet(
      item: $keyEditor,
      onDismiss: {
        if let provider = pendingReclassification {
          pendingReclassification = nil
          reclassifyTarget = targetName(provider)
        }
      }
    ) { provider in
      APIKeyEditSheet(settings: settings, provider: provider) { firstKeyAdded in
        configurationChanged()
        if firstKeyAdded { pendingReclassification = provider }
      }
    }
    .task(id: "\(settings.provider.rawValue)|\(settings.keyRevision)") {
      await settings.refreshKey()
      guard !Task.isCancelled else { return }
      if pendingProviderSelection == settings.provider {
        pendingProviderSelection = nil
        if settings.provider == .appleFM || settings.hasStoredKey { reclassifyTarget = targetName(settings.provider) }
      }
    }
    .task(id: modelFetchKey) { await refreshModelList() }
    .alert("Reclassify Articles?", isPresented: Binding(get: { reclassifyTarget != nil }, set: { if !$0 { reclassifyTarget = nil } })) {
      Button("Reclassify", role: .destructive) {
        Task {
          if let writer = syncEngine.writer { await classificationEngine.reclassifyAll(writer: writer) }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Reclassify existing articles with \(reclassifyTarget ?? "the selected provider")? This replaces their category assignments.")
    }
  }

  private func selectProvider(_ provider: ClassificationProviderKind) {
    guard provider != settings.provider else { return }
    pendingProviderSelection = provider
    settings.select(provider)
    configurationChanged()
  }

  private func selectModel(_ model: String) {
    guard model != modelSelection else { return }
    modelSelection = model
    // Persist only on an explicit user pick. A programmatic write pins a user
    // who never picked to the current default.
    if !settings.isInert { OpenAIModelSetting.persist(model) }
    configurationChanged()
    if settings.hasStoredKey { reclassifyTarget = targetName(.openAI) }
  }

  private func configurationChanged() {
    guard !settings.isInert, let writer = syncEngine.writer else { return }
    classificationEngine.configurationChanged(writer: writer)
  }

  private func targetName(_ provider: ClassificationProviderKind) -> String {
    switch provider {
    case .appleFM: provider.displayName
    case .openAI: "OpenAI (\(modelSelection))"
    case .vercel: "JEV through Vercel AI Gateway"
    }
  }

  private var modelFetchKey: String { "\(settings.provider.rawValue)|\(settings.keyRevision)|\(settings.hasStoredKey)" }

  private func refreshModelList() async {
    guard settings.provider == .openAI else { return }
    guard let apiKey = await settings.keyForModelList() else {
      modelListState = .needsKey
      return
    }
    modelListState = .loading
    let outcome: Result<[OpenAIModel], OpenAIModelsError>
    do throws(OpenAIModelsError) {
      outcome = .success(try await OpenAIModelsClient().fetchModels(apiKey: apiKey))
    } catch { outcome = .failure(error) }
    // A cancelled fetch surfaces as a network failure. Do not show a failure
    // this view abandoned.
    guard !Task.isCancelled else { return }
    modelListState = resolveModelListState(outcome: outcome)
  }
}

extension ClassificationProviderKind: Identifiable {
  var id: String { rawValue }
}

private struct APIKeyEditSheet: View {
  let settings: ClassificationSettingsModel
  let provider: ClassificationProviderKind
  let onCommit: (Bool) -> Void
  @Environment(\.dismiss)
  private var dismiss
  @Environment(AppFontSettings.self)
  private var fontSettings
  @State
  private var editKey = ""
  @State
  private var errorMessage: String?
  @FocusState
  private var isKeyFocused: Bool
  @State
  private var operation: KeyEditOperation?

  private enum KeyEditOperation: Equatable {
    case save(String)
    case remove
  }

  init(
    settings: ClassificationSettingsModel, provider: ClassificationProviderKind,
    errorMessage: String? = nil, onCommit: @escaping (Bool) -> Void
  ) {
    self.settings = settings
    self.provider = provider
    self.onCommit = onCommit
    _errorMessage = State(initialValue: errorMessage)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("\(provider.displayName) API Key").font(fontSettings.headline)
      SecureField("Enter API key", text: $editKey)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("\(provider.displayName) API key")
        .accessibilityIdentifier("classification.key.field")
        .focused($isKeyFocused)
      if settings.hasStoredKey {
        Label("A key is currently saved", systemImage: "checkmark.circle")
          .font(fontSettings.caption)
      }
      if let operation {
        ProgressView(operation == .remove ? "Removing API key…" : "Saving API key…")
          .controlSize(.small)
      }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(fontSettings.caption)
      }
      HStack {
        if settings.hasStoredKey {
          Button("Remove Key", role: .destructive) { operation = .remove }
            .accessibilityIdentifier("classification.key.remove")
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") { operation = .save(editKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
          .keyboardShortcut(.defaultAction)
          .disabled(editKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("classification.key.save")
      }
    }
    .disabled(operation != nil)
    .padding()
    .frame(width: 400)
    .interactiveDismissDisabled(operation != nil)
    .task(id: operation) {
      if let operation { await perform(operation) }
    }
    .onAppear { isKeyFocused = true }
  }

  private func perform(_ operation: KeyEditOperation) async {
    let hadKey = settings.hasStoredKey
    // Report only a write the store accepted, so the parent never shows a key
    // as saved after a failed write.
    do {
      switch operation {
      case .save(let value): try await settings.save(value, for: provider)
      case .remove: try await settings.removeKey(for: provider)
      }
      // A completed Security write must reach the engine even if dismissal cancels the view task.
      onCommit(operation != .remove && !hadKey)
      dismiss()
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage =
        operation == .remove
        ? "Could not remove the API key from Keychain. Try again." : "Could not save the API key to Keychain. Try again."
      self.operation = nil
    }
  }
}

#Preview("Vercel — needs key") {
  ClassificationSettingsView(settings: ClassificationSettingsModel(provider: .vercel, isInert: true))
    .environment(SyncEngine()).environment(ClassificationEngine()).environment(AppFontSettings())
    .frame(width: 420, height: 450)
}

#Preview("Vercel — saved key") {
  ClassificationSettingsView(
    settings: ClassificationSettingsModel(
      provider: .vercel, store: MemoryClassificationKeyStore(values: [.vercel: "preview"]), isInert: true)
  )
  .environment(SyncEngine()).environment(ClassificationEngine()).environment(AppFontSettings())
  .frame(width: 550, height: 550)
}

private struct ClassificationSettingsPreview: View {
  private let engine: ClassificationEngine
  private let provider: ClassificationProviderKind
  private let hasKey: Bool

  init(provider: ClassificationProviderKind = .vercel, reason: ClassificationAbortReason? = nil, hasKey: Bool = true) {
    self.provider = provider
    self.hasKey = hasKey
    engine = ClassificationEngine(providerFactoryOverride: { HeadlessClassificationProvider() })
    engine.applyPreviewState(lastAbort: reason, provider: provider)
  }

  var body: some View {
    ClassificationSettingsView(
      settings: ClassificationSettingsModel(
        provider: provider,
        store: MemoryClassificationKeyStore(values: hasKey ? [provider: "preview"] : [:]),
        isInert: true)
    )
    .environment(SyncEngine()).environment(engine)
    .environment(AppFontSettings(textSize: .xxLarge))
    .frame(width: 420, height: 550)
  }
}

#Preview("Vercel — offline") { ClassificationSettingsPreview(reason: .offline) }
#Preview("Vercel — invalid key") { ClassificationSettingsPreview(reason: .keyRejected) }
#Preview("Vercel — service limit") { ClassificationSettingsPreview(reason: .rateLimited) }
#Preview("Vercel — rejected request") { ClassificationSettingsPreview(reason: .modelRejected) }
#Preview("Vercel — invalid response") { ClassificationSettingsPreview(reason: .invalidResponse) }
#Preview("Vercel — invalid categories") {
  ClassificationSettingsPreview(reason: .invalidCategories).preferredColorScheme(.dark)
}
#Preview("Vercel — large categories") { ClassificationSettingsPreview(reason: .inputTooLarge) }
#Preview("Vercel — unavailable") { ClassificationSettingsPreview(reason: .providerUnavailable) }
#Preview("OpenAI — invalid key") { ClassificationSettingsPreview(provider: .openAI, reason: .keyRejected) }
#Preview("OpenAI — service limit") { ClassificationSettingsPreview(provider: .openAI, reason: .rateLimited) }
#Preview("Vercel — key sheet") {
  APIKeyEditSheet(settings: ClassificationSettingsModel(provider: .vercel, isInert: true), provider: .vercel, onCommit: { _ in })
    .environment(AppFontSettings())
}
#Preview("Vercel — Keychain denied") {
  APIKeyEditSheet(
    settings: ClassificationSettingsModel(provider: .vercel, isInert: true), provider: .vercel,
    errorMessage: "Could not save the API key to Keychain. Try again.", onCommit: { _ in }
  )
  .environment(AppFontSettings(textSize: .xxLarge))
  .preferredColorScheme(.dark)
}

// MARK: - OpenAI model picker row

/// Keep the menu usable with fallback options when model discovery fails.
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
      // The loaded list passes the option-count threshold for a menu (STACK.md § 11).
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
