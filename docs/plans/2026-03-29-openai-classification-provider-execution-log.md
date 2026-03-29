# Execution Log: Optional OpenAI Classification Provider

**Date:** 2026-03-29
**Plan:** `docs/plans/2026-03-29-openai-classification-provider-plan.md`
**Branch:** `worktree-feat+openai-classification`

## Milestones

### M0: ClassificationProvider protocol + Apple FM adapter — DONE
- Created `ClassificationProvider` protocol in `Feeder/Classification/ClassificationProvider.swift`
- Extracted `ArticleClassification` @Generable struct and Apple FM logic into `AppleFMClassificationProvider`
- Both providers marked `nonisolated struct` for Swift 6 strict concurrency compliance
- Refactored `ClassificationEngine.classifyNextBatch()` to delegate to provider
- Build: zero warnings, zero errors

### M1: OpenAI provider implementation — DONE
- Created `OpenAIClassificationProvider` in `Feeder/Classification/OpenAIClassificationProvider.swift`
- Pure URLSession HTTP call to Chat Completions API with structured outputs
- JSON schema enforces `categories`, `storyKey`, `confidence` fields
- `temperature: 0` for deterministic output
- Error types: `invalidResponse`, `apiError(statusCode, message)`, `emptyResponse`
- No third-party dependencies

### M2: Settings UI — DONE
- Created `ClassificationSettingsView` with radio group picker (Apple FM / OpenAI)
- SecureField for API key with save/clear actions
- Key stored in Keychain via existing `KeychainHelper`
- Provider selection persisted to UserDefaults (`classification_provider`)
- Switching provider prompts reclassification alert
- Added as fourth tab in `SettingsView`

### M3: Wire provider selection — DONE (included in M0)
- `makeProvider()` factory in ClassificationEngine reads UserDefaults
- Language filtering conditional: only applied for Apple FM
- Progress text shows active provider name

### M4: Build verification and test gate — DONE
- Fixed swift-format lint: replaced force-unwrapped URL with guard-let closure
- test-all.sh: ALL GREEN (4/4 phases passed)
  - swift-format lint: PASS
  - Build: PASS (zero warnings)
  - Unit tests: PASS (7/7)
  - UI smoke tests: PASS (4/4)

## Files Changed

| File | Action | Purpose |
|------|--------|---------|
| `Feeder/Classification/ClassificationProvider.swift` | New | Protocol + Apple FM provider + ProviderClassificationResult DTO |
| `Feeder/Classification/OpenAIClassificationProvider.swift` | New | OpenAI provider with URLSession + structured outputs |
| `Feeder/Classification/ClassificationEngine.swift` | Modified | Refactored to use provider protocol, added makeProvider factory |
| `Feeder/Views/ClassificationSettingsView.swift` | New | Settings tab for provider selection + API key |
| `Feeder/Views/SettingsView.swift` | Modified | Added Classification tab |
| `docs/research/2026-03-29-openai-classification-provider.md` | New | Research dossier |
| `docs/plans/2026-03-29-openai-classification-provider-plan.md` | New | Implementation plan |

## Decisions Made During Implementation

1. **Merged M0+M1+M3** into a single implementation pass — the provider protocol, both implementations, and the wiring are naturally coupled
2. **Used `nonisolated struct`** for both providers instead of classes — simpler, Sendable by default
3. **Static endpoint URL** with guard-let closure to satisfy swift-format's NeverForceUnwrap rule
4. **Body truncation:** Apple FM uses 3800*4 chars (context budget), OpenAI uses 60K chars (well under 400K token limit)
