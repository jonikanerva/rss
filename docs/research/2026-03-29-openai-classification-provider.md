# Research: Optional OpenAI Classification Provider

**Date:** 2026-03-29
**Status:** Complete — ready for plan phase

## 1. Problem

Feeder currently uses Apple Foundation Models (on-device ~3B, 2-bit quantized) for article classification. While free and private, the model has known limitations:

- Limited accuracy on nuanced multi-label classification (3B parameters, constrained decoding)
- Language support limited to Apple FM supported languages
- No fallback when the on-device model produces low-confidence results
- Apple FM benchmarks show competitive performance vs similar-sized open models (Qwen-2.5-3B, Gemma-3-4B) but significantly trail cloud models like GPT-4o+ on classification tasks

**Goal:** Add an optional OpenAI provider (GPT-5.4-nano) as an alternative classification backend, selectable in Settings alongside Apple Foundation Models.

## 2. Constraints

### Technical
- **Swift 6 strict concurrency** — all new code must be `Sendable`, actor-isolated correctly
- **Two-layer architecture** — inference must run in background (DataWriter/detached Task), not on MainActor
- **No new frameworks** beyond SPM packages — no Combine, no GCD
- **macOS 26+** target — can use latest Swift/SwiftUI features
- **Structured output** — current system uses `@Generable` for constrained decoding; OpenAI equivalent is `response_format: json_schema`

### Product
- Apple FM must remain the default (free, private, no account needed)
- OpenAI must be opt-in — user explicitly enables it in Settings
- User provides their own API key (no proxy server, no shared billing)
- API key must be stored securely (macOS Keychain)

### Cost
- GPT-5.4-nano pricing: **$0.20/1M input, $1.25/1M output**
- Typical article: ~500 tokens input, ~50 tokens output ≈ $0.0001625/article
- 100 articles/day ≈ **$0.49/month** — very affordable

## 3. Alternatives

### Option A: OpenAI GPT-5.4-nano via direct API (Recommended)

**Approach:** Add OpenAI as an alternative classification provider using a community Swift SDK (MacPaw/OpenAI or SwiftOpenAI). User enters API key in Settings, stored in Keychain.

**Pros:**
- GPT-5.4-nano is specifically designed for classification tasks
- Structured Outputs guarantee valid JSON schema responses
- 400K context window (vs ~4K effective for Apple FM)
- Multilingual — no language restriction
- Very cheap ($0.49/month for typical usage)
- Well-established Swift SDKs available (MacPaw/OpenAI supports Swift 6)
- Simple auth: API key in Keychain, no OAuth complexity

**Cons:**
- Requires internet connection
- Article content sent to OpenAI servers (privacy concern for some users)
- Adds SPM dependency
- API key management UX (user must create OpenAI account, generate key)
- Rate limits / outages possible

### Option B: OpenAI with OAuth / browser login

**Approach:** User authenticates via browser-based OAuth flow, using their OpenAI account.

**Pros:**
- No manual API key copy-paste
- Potentially smoother UX

**Cons:**
- **OpenAI does not offer a consumer OAuth flow for API access.** OAuth is available only for the Apps SDK (ChatGPT plugins/actions) and Codex, not for direct API usage. Regular API access requires API keys.
- Would need a proxy/intermediary server to handle OAuth token → API calls
- Massively increases complexity for minimal UX benefit
- Privacy concerns amplified (intermediary server sees all data)

**Verdict:** Not viable. OpenAI API authentication is API-key-only for direct access.

### Option C: OpenRouter as intermediary

**Approach:** Use OpenRouter (openrouter.ai) which offers OAuth PKCE for end users and proxies to OpenAI models.

**Pros:**
- OAuth PKCE browser flow available for native apps
- User pays OpenRouter directly, no API key needed
- Supports GPT-5.4-nano and many other models

**Cons:**
- Adds intermediary (privacy, latency, availability)
- OpenRouter markup on pricing
- Additional dependency on third-party service
- Less mainstream than direct OpenAI

### Option D: Hybrid — Apple FM primary, OpenAI fallback for low-confidence

**Approach:** Keep Apple FM as the primary classifier. When confidence < threshold, automatically re-classify with OpenAI.

**Pros:**
- Minimizes API calls (only low-confidence articles)
- Best of both worlds: privacy for easy cases, accuracy for hard ones
- Could reduce cost to near-zero for well-categorized feeds

**Cons:**
- More complex logic (two-pass classification)
- User still needs API key configured
- Latency increase for fallback articles

**Note:** This could be a future enhancement on top of Option A.

## 4. Evidence

### GPT-5.4-nano capabilities
- **Model ID:** `gpt-5.4-nano`
- **Pricing:** $0.20/1M input, $1.25/1M output tokens
- **Context:** 400K tokens
- **Designed for:** classification, data extraction, ranking, sub-agents
- **Structured Outputs:** Supported via `response_format: { type: "json_schema" }`
- **Source:** [OpenAI GPT-5.4-nano docs](https://developers.openai.com/api/docs/models/gpt-5.4-nano), [Pricing](https://developers.openai.com/api/docs/pricing)

### Classification benchmarks
- GPT-5.4-nano on subtle classification benchmark: **~85% accuracy** (tied with Gemini 3.1 Flash Lite) — [OpenMark benchmark](https://openmark.ai/best-ai-for-classification)
- Apple FM on-device 3B: **67.85% MMLU** — competitive with Qwen-2.5-3B but below cloud models
- GPT-4.1-nano MMLU: **80.1%** — GPT-5.4-nano expected to exceed this
- Real-world zero-shot classification with GPT models: **89-93% accuracy** reported
- **Source:** [Apple FM tech report](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025), [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/gpt-5-nano-vs-gpt-4-1-nano)

### Swift SDK options
| Package | Swift 6 | Structured Outputs | Maintained | Stars |
|---------|---------|-------------------|------------|-------|
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | ✅ | ✅ (JSON Schema) | Active (3mo ago) | High |
| [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) | ✅ | ✅ | Active | High |
| [OpenAIKit](https://github.com/OpenDive/OpenAIKit) | ✅ (6.2) | Unclear | Active | Medium |

**No official OpenAI Swift SDK exists.** OpenAI provides official SDKs for Python, JavaScript, Go (beta), C# only. Community packages are the standard for Swift.

### Authentication
- **API key auth:** Bearer token in Authorization header. Simple, well-documented.
- **OAuth for API:** Not available. OAuth exists only for Apps SDK (ChatGPT plugins) and Codex.
- **Keychain storage:** Standard macOS pattern. [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) library or native Security framework.
- **Source:** [OpenAI auth docs](https://developers.openai.com/api/docs/libraries), [Apple Keychain docs](https://developer.apple.com/documentation/security/keychain-services)

### Architecture fit
Current codebase is well-prepared for multi-provider:
- `ClassificationInput` / `ClassificationResult` / `CategoryDefinition` are `nonisolated struct` + `Sendable`
- Pure functions for prompt building, confidence gating, keyword matching
- All inference happens in `Task.detached(priority: .utility)` — provider-agnostic
- Settings UI has clear extension points (tabs)

**Required changes:**
1. New `ClassificationProvider` protocol with Apple FM and OpenAI implementations
2. Settings UI: provider picker + API key field
3. API key storage via Keychain
4. OpenAI provider: HTTP call with structured output JSON schema
5. Minor refactor of `ClassificationEngine` to use provider protocol

## 5. Unknowns

### Resolved
- ✅ OAuth feasibility → Not viable for OpenAI API. API key only.
- ✅ Cost → Very affordable (~$0.49/month for typical usage)
- ✅ Swift SDK availability → Multiple mature options exist
- ✅ Structured output support → GPT-5.4-nano supports JSON schema

### Open questions
- **Accuracy delta on our specific categories:** Benchmarks are general-purpose. We don't know how much better GPT-5.4-nano will perform on our specific 15-category taxonomy vs Apple FM until we test it. This is the **biggest risk** — the improvement may be marginal for well-keyworded categories.
- **SDK choice:** MacPaw/OpenAI vs SwiftOpenAI — need to verify Swift 6 strict concurrency compatibility and structured output API surface.
- **Rate limiting:** GPT-5.4-nano rate limits for free-tier / low-tier API keys. May need backoff logic.
- **Network error handling:** What happens when OpenAI is unreachable? Fall back to Apple FM? Queue for retry?

### Biggest risk
**The accuracy improvement over Apple FM may not justify the added complexity and privacy tradeoff.** We should plan an A/B evaluation phase where we classify a sample batch with both providers and compare results before fully committing.

## 6. Recommendation

**Evidence is sufficient to proceed to planning.** Recommend Option A (direct OpenAI API with API key) with the following plan scope:

1. **Provider protocol** abstracting classification backend
2. **OpenAI provider** using a community Swift SDK with structured outputs
3. **Settings UI** with provider picker and secure API key field
4. **Keychain storage** for API key
5. **A/B evaluation mode** (classify with both, log comparison) before making it user-facing

Option D (hybrid fallback) is a natural future enhancement but should not be in initial scope — keep it simple with a clean toggle.

OAuth/browser login is **not feasible** for OpenAI API access. API key entry is the only supported method.
