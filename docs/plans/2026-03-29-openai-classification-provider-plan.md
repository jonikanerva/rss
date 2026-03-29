# Plan: Optional OpenAI Classification Provider

**Date:** 2026-03-29
**Research:** `docs/research/2026-03-29-openai-classification-provider.md`
**Branch:** `worktree-feat+openai-classification`

## 1. Scope

Add GPT-5.4-nano as an optional classification backend alongside Apple Foundation Models. Users select provider in Settings and enter their OpenAI API key. The system uses the same prompt, categories, confidence gating, and keyword matching regardless of provider — only the inference call differs.

**Out of scope:** hybrid fallback mode, cost tracking UI, OpenRouter/OAuth, fine-tuning.

## 2. Milestones

### M0: ClassificationProvider protocol + Apple FM adapter

**Goal:** Extract current Apple FM inference into a protocol so both providers share the same interface. Zero behavior change.

**Files:**
- New: `Feeder/Classification/ClassificationProvider.swift` — protocol + Apple FM implementation
- Edit: `Feeder/Classification/ClassificationEngine.swift` — use provider instead of inline FM code

**Protocol design:**
```swift
/// A classification backend that takes article text and returns structured classification.
protocol ClassificationProvider: Sendable {
    var name: String { get }
    var isAvailable: Bool { get async }

    func classify(
        title: String,
        body: String,
        instructions: String,
        validLabels: Set<String>
    ) async throws -> ProviderClassificationResult
}

/// Raw output from a provider before confidence gating.
nonisolated struct ProviderClassificationResult: Sendable {
    let categories: [String]
    let storyKey: String
    let confidence: Double
}
```

**Apple FM adapter:** Wraps current `LanguageModelSession` + `ArticleClassification` @Generable logic. The `@Generable` struct stays in this file since it's Apple FM-specific.

**Acceptance criteria:**
- `ClassificationEngine.classifyNextBatch()` delegates inference to `ClassificationProvider`
- All pure helper functions (confidence gate, keyword match, etc.) remain unchanged
- Behavior identical to current — existing tests/manual verification pass
- Build: zero warnings, zero errors

**Confidence:** High

---

### M1: OpenAI provider implementation

**Goal:** Implement `OpenAIClassificationProvider` conforming to `ClassificationProvider`.

**Files:**
- New: `Feeder/Classification/OpenAIClassificationProvider.swift`

**Approach:** Direct `URLSession` HTTP call to OpenAI Chat Completions API — no third-party SDK dependency. This avoids SPM dependency management, Swift 6 compatibility concerns, and keeps the codebase lean. The API surface needed is tiny (one endpoint, one model, structured output).

**HTTP call structure:**
```
POST https://api.openai.com/v1/chat/completions
Authorization: Bearer {api_key}
Content-Type: application/json

{
  "model": "gpt-5.4-nano",
  "messages": [
    {"role": "system", "content": "{instructions}"},
    {"role": "user", "content": "title: {title}\ncontent: {body}"}
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "article_classification",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "categories": {"type": "array", "items": {"type": "string"}},
          "storyKey": {"type": "string"},
          "confidence": {"type": "number"}
        },
        "required": ["categories", "storyKey", "confidence"],
        "additionalProperties": false
      }
    }
  },
  "temperature": 0
}
```

**Key decisions:**
- `temperature: 0` for deterministic output (equivalent to Apple FM's greedy sampling)
- Structured Outputs with `strict: true` guarantees valid JSON matching our schema
- Body truncation: same `maxContextChars` budget as Apple FM (conservative, well under 400K limit)
- API key read from Keychain at call time (not cached in memory)
- No language filtering — GPT-5.4-nano handles all languages

**Error handling:**
- Network error → throw, ClassificationEngine catches and marks article as uncategorized (existing behavior)
- 401 Unauthorized → log specific error, provider reports `isAvailable = false`
- 429 Rate limited → throw with retry-after hint (ClassificationEngine's 2s polling loop naturally retries)

**Acceptance criteria:**
- Conforms to `ClassificationProvider`
- Parses structured output into `ProviderClassificationResult`
- No third-party dependencies (pure URLSession + JSONDecoder)
- Handles API errors gracefully
- `nonisolated` or `Sendable` — safe to call from detached Task
- Build: zero warnings, zero errors

**Confidence:** High

---

### M2: Settings UI — provider picker + API key

**Goal:** Add a "Classification" tab to SettingsView where users select provider and enter OpenAI API key.

**Files:**
- Edit: `Feeder/Views/SettingsView.swift` — add fourth tab
- New: `Feeder/Views/ClassificationSettingsView.swift` — classification tab content

**UserDefaults keys:**
- `"classification_provider"` — String: `"apple_fm"` (default) or `"openai"`

**Keychain key:**
- `"openai_api_key"` — stored via existing `KeychainHelper`

**UI layout:**
```
Classification Tab:
┌─────────────────────────────────────────┐
│ Classification Provider                 │
│ ┌─────────────────────────────────────┐ │
│ │ [●] Apple Foundation Models         │ │
│ │     Free · On-device · Private      │ │
│ │ [ ] OpenAI GPT-5.4-nano             │ │
│ │     Requires API key · Cloud-based  │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ OpenAI API Key  [••••••••••••] [Clear]  │
│ (shown only when OpenAI selected)       │
│                                         │
│ Status: ✓ Key valid / ⚠ No key set     │
│                                         │
│ [Reclassify All Articles]               │
└─────────────────────────────────────────┘
```

**Behavior:**
- Provider picker persists immediately to UserDefaults
- API key field: SecureField, saves to Keychain on commit (onSubmit or focus loss)
- "Clear" button removes key from Keychain
- Status indicator: checks if key is non-empty (no API validation call — too expensive for settings)
- "Reclassify All" triggers `classificationEngine.reclassifyAll(writer:)` (existing functionality, moved from CategoryManagementView or duplicated)
- Switching provider triggers reclassification prompt (alert: "Reclassify all articles with new provider?")

**Acceptance criteria:**
- Tab renders correctly, picker works
- API key stored/loaded from Keychain
- Provider selection persisted in UserDefaults
- Build: zero warnings, zero errors

**Confidence:** High

---

### M3: Wire provider selection into ClassificationEngine

**Goal:** ClassificationEngine reads the selected provider from UserDefaults and instantiates the correct `ClassificationProvider` for each batch.

**Files:**
- Edit: `Feeder/Classification/ClassificationEngine.swift`

**Logic:**
```swift
private nonisolated func makeProvider() -> any ClassificationProvider {
    let selection = UserDefaults.standard.string(forKey: "classification_provider") ?? "apple_fm"
    switch selection {
    case "openai":
        let apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
        return OpenAIClassificationProvider(apiKey: apiKey)
    default:
        return AppleFMClassificationProvider()
    }
}
```

**Changes to `classifyNextBatch()`:**
- Replace inline `SystemLanguageModel` / `LanguageModelSession` code with `provider.classify()` call
- Remove `supportedLangCodes` filtering when using OpenAI (it supports all languages)
- Keep all other logic identical: keyword matching, confidence gating, deepest-match enforcement

**Provider availability check:**
- If `provider.isAvailable` returns false (e.g., no API key, model unavailable), log and skip batch
- Progress UI shows which provider is active: "Categorizing 3/10 (OpenAI)" or "Categorizing 3/10 (Apple FM)"

**Acceptance criteria:**
- Switching provider in Settings changes classification behavior
- Apple FM path behaves identically to before refactor
- OpenAI path calls API and produces valid ClassificationResults
- Language filtering only applied for Apple FM, not OpenAI
- Progress text shows active provider
- Build: zero warnings, zero errors

**Confidence:** High

---

### M4: End-to-end testing and polish

**Goal:** Verify the full flow works correctly with both providers. Fix edge cases.

**Tasks:**
1. Manual test: classify 20+ articles with Apple FM, note results
2. Manual test: classify same articles with OpenAI, compare results
3. Verify: switching providers and reclassifying works cleanly
4. Verify: removing API key gracefully falls back / shows error
5. Verify: network failure during OpenAI classification handles gracefully
6. Run `bash .claude/scripts/test-all.sh` — all green
7. Run build verification — zero warnings, zero errors

**Edge cases to verify:**
- Empty API key + OpenAI selected → clear error in logs, classification skipped
- API key with no credit → 402 error handled gracefully
- Very long articles → body truncation works for both providers
- Non-English articles → OpenAI classifies, Apple FM skips unsupported languages
- Rapid provider switching during active classification

**Acceptance criteria:**
- Both providers produce reasonable classification results
- No crashes, no unhandled errors
- All tests pass
- Build clean

**Confidence:** Medium (depends on API behavior in practice)

## 3. Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| GPT-5.4-nano accuracy not significantly better than Apple FM for our categories | Medium | Medium | M4 comparison will reveal this; feature still useful as user choice |
| URLSession sandbox restrictions in macOS app | High | Low | Standard macOS apps have network entitlement; test early in M1 |
| OpenAI API response format changes | Medium | Low | Structured Outputs with strict schema are contractual; version-pin model ID |
| Swift 6 concurrency issues with URLSession | Medium | Low | URLSession.data(for:) is already async/Sendable-safe |
| API key security — key in memory during request | Low | Low | Read from Keychain per-request, not cached; standard practice |

## 4. Confidence

| Milestone | Confidence | Notes |
|-----------|------------|-------|
| M0: Provider protocol | High | Pure refactor, no new behavior |
| M1: OpenAI provider | High | Simple HTTP + JSON, well-documented API |
| M2: Settings UI | High | Follows existing SettingsView patterns |
| M3: Wire it up | High | Straightforward delegation |
| M4: Testing | Medium | Depends on real API behavior and accuracy comparison |

## 5. Quality Gates

### Before PR creation
- [ ] `bash .claude/scripts/test-all.sh` — all green
- [ ] `xcodebuild` build — zero warnings, zero errors
- [ ] Manual test: Apple FM classification works as before (regression check)
- [ ] Manual test: OpenAI classification produces valid results
- [ ] Manual test: Settings UI provider switch + API key flow
- [ ] Manual test: Error handling (no key, bad key, no network)

### Code quality
- [ ] Swift 6 strict concurrency — no warnings
- [ ] No `@unchecked Sendable` hacks
- [ ] No third-party SPM dependencies added
- [ ] API key never logged or exposed in UI (except masked SecureField)
- [ ] All new types documented with purpose comments

### Architecture compliance
- [ ] No ModelContext on MainActor for writes
- [ ] All inference in background (Task.detached or actor)
- [ ] DTOs are `nonisolated struct` + `Sendable`
- [ ] Provider protocol is `Sendable`
