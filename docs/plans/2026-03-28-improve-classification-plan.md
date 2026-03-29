# Plan: Improve Apple FM Classification Accuracy

**Date:** 2026-03-28
**Research:** [docs/research/2026-03-28-improve-classification-accuracy.md](../research/2026-03-28-improve-classification-accuracy.md)

---

## 1. Scope

Improve the accuracy of on-device article classification using Apple Foundation Models. The model currently misclassifies articles — assigning wrong categories or classifying completely empty articles. This plan addresses the problem through five targeted changes, all within the existing Apple FM pipeline.

**In scope:**
- Input validation gate for completely empty articles (no title AND no body)
- Keyword match confidence signal (0.0–1.0) with future-proof `keywords` field on Category
- `contentTagging` adapter (if available in SDK)
- Prompt engineering improvements
- Confidence field via `@Guide` on `ArticleClassification`
- Confidence gate combining keyword + LLM confidence to route low-confidence results to "Uncategorized"

**Out of scope:** OpenAI/cloud fallback, NLEmbedding ensemble, LoRA adapter training.

---

## 2. Milestones

### M0: Replace Default Categories

**What:** Replace the current default category set with a new, expanded taxonomy. Removes `world` (renamed to `world_news`), adds `rivian`, `marathon`, `science`, `whisky`, `buddhism`. Restructures hierarchy and improves descriptions.

**Where:** `FeederApp.swift`, `seedDefaultCategories()` function.

**New category tree:**

| Label | Parent | Description |
|---|---|---|
| `gaming` | — | Video game releases, reviews, gameplay content, announcements, and all game-specific news. |
| `playstation_5` | gaming | News about PlayStation 5 games, hardware, and ecosystem. Multiplatform news is acceptable if PS5 is one of the platforms. Exclude mobile gaming, PC-only gaming, and other console news. |
| `marathon` | gaming | Articles about Marathon, the video game by developer Bungie. |
| `gaming_industry` | gaming | Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes. |
| `technology` | — | A broad category for all news about technology companies, products, platforms, and innovations. |
| `apple` | technology | All news related to Apple Inc., its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series, A-series), services, and innovations. |
| `tesla` | technology | All news related to Tesla Inc., its vehicles, energy products, and innovations. |
| `rivian` | technology | All news related to Rivian Automotive, its electric vehicles, technology, and business developments. |
| `ai` | technology | Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies (OpenAI, Anthropic), and applied generative AI. Do not apply when a product merely uses AI as a feature. |
| `home_automation` | technology | Smart home devices, appliances, home automation platforms (Home Assistant, Google Home, Apple HomeKit, Amazon Alexa), protocols (Matter, Thread, Z-Wave, Zigbee), and related IoT technologies for the home. |
| `science` | — | Scientific discoveries, research, space exploration, astronomy, rockets, NASA, ESA, and related topics. |
| `world_news` | — | Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries. |
| `whisky` | — | Articles about whisky — distilleries, reviews, tastings, industry news, and culture. |
| `buddhism` | — | Articles about Buddhism, meditation, mindfulness, and spiritual topics. Do not include general health or fitness articles. |
| `uncategorized` | — | Use only when no other category clearly matches. Never combine with another category. (System, immutable) |

**Changes:**
- Replace entire `defaults` array in `seedDefaultCategories()`
- Update sort orders to reflect new hierarchy
- Rename `world` → `world_news` (label change)
- Add new categories: `rivian`, `marathon`, `science`, `whisky`, `buddhism`
- Remove old `world` label
- Update M2 keyword seeds to cover new categories

**Acceptance criteria:**
- Fresh launch seeds all 15 categories with correct hierarchy
- Descriptions match the table above
- Schema version bump triggers article reset (categories preserved via separate seeding path)
- Build passes

**Confidence:** High

---

### M1: Input Validation Gate

**What:** Skip classification entirely when an article has no meaningful content — both title is "Untitled" (the default) AND body is empty. Assign `["uncategorized"]` directly without invoking the model.

**Where:** `ClassificationEngine.swift`, inside the `for input in inputs` loop (line 119), before language detection.

**Changes:**
- Add a check: `if input.title == "Untitled" && input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`
- Return `ClassificationResult` with `[uncategorizedLabel]` immediately
- Add unit test for this gate

**Acceptance criteria:**
- Articles with no title and no body → "Uncategorized" without LLM call
- Articles with only a title → still classified by LLM
- Articles with only a body → still classified by LLM
- Existing tests pass

**Confidence:** High

---

### M2: Keyword Match Confidence

**What:** Add a keyword-based classification signal that produces a confidence score (0.0–1.0). When a category's keywords appear in the article title or body, that category gets a confidence boost. This runs before LLM inference — cheap and deterministic.

**Future-proofing:** Add a `keywords: [String]` field to the `Category` model so users can later manage keywords per category in Settings UI. For now, auto-derive keywords from `label` and `displayName` (e.g., category "playstation_5" matches keywords ["playstation 5", "ps5"]).

**Where:**
- `Category.swift` — add `keywords: [String]` field (schema version bump required)
- `CategoryDefinition` DTO — add `keywords: [String]`
- New pure function `keywordMatchConfidence()` in `ClassificationEngine.swift`
- Seed default keywords in `seedDefaultCategories()`

**Changes:**
1. Add `keywords: [String]` to `Category` model (default: `[]`)
2. Add `keywords` to `CategoryDefinition` DTO and `fetchCategoryDefinitions()`
3. Seed sensible default keywords for all categories:
   - `technology` → ["tech"]
   - `apple` → ["apple", "iphone", "ipad", "macbook", "macos", "ios", "watchos", "airpods", "apple watch", "vision pro", "apple intelligence"]
   - `tesla` → ["tesla", "cybertruck", "model 3", "model y", "model s", "model x", "supercharger"]
   - `rivian` → ["rivian", "r1t", "r1s", "r2", "r3"]
   - `ai` → ["openai", "chatgpt", "anthropic", "claude", "gemini", "llama", "midjourney", "stable diffusion", "machine learning", "deep learning", "neural network"]
   - `gaming` → ["xbox", "nintendo", "steam", "epic games"]
   - `gaming_industry` → ["layoffs", "acquisition", "studio closure"]
   - `playstation_5` → ["playstation 5", "ps5", "dualsense", "psn", "playstation"]
   - `marathon` → ["marathon", "bungie"]
   - `home_automation` → ["homekit", "home assistant", "matter", "alexa", "google home", "smart home", "zigbee", "thread", "z-wave"]
   - `science` → ["nasa", "esa", "spacex", "rocket", "asteroid", "exoplanet", "james webb", "hubble"]
   - `world_news` → [] (too broad for keywords)
   - `whisky` → ["whisky", "whiskey", "scotch", "bourbon", "distillery", "single malt", "islay"]
   - `buddhism` → ["buddhism", "buddhist", "meditation", "dharma", "mindfulness", "zen"]
   - `uncategorized` → [] (never matched by keywords)
4. Pure function: `keywordMatchConfidence(input: ClassificationInput, categories: [CategoryDefinition]) -> [String: Double]`
   - Case-insensitive search in title + body
   - Title match weighs more than body match (title hit: 0.8, body-only hit: 0.4)
   - Multiple keyword hits in same category increase confidence (capped at 1.0)
   - Returns dict of `categoryLabel → confidence` for all categories with any match
5. Bump `currentSchemaVersion` in `FeederApp.swift`
6. Add unit tests for keyword matching logic

**Acceptance criteria:**
- `Category` model has `keywords: [String]` field
- Default categories seeded with sensible keywords
- `keywordMatchConfidence()` returns correct scores for known test cases
- Schema version bumped
- All tests pass

**Confidence:** High — pure string matching, no API risk.

---

### M3: Prompt Engineering Improvements

**What:** Tighten the system prompt to reduce misclassifications. Current prompt (`buildClassificationInstructions`) is 3 lines plus the category list. Improvements:

1. **Add explicit negative instruction:** Tell the model to return `uncategorized` when evidence is insufficient or ambiguous.
2. **Add "uncategorized" to the category list** in the prompt — currently it's only in the DB but not in the instructions the LLM sees. The model can't choose it if it doesn't know it exists.
3. **Tighten category descriptions** — review each for clarity and overlap reduction.
4. **Limit output scope** — instruct the model that fewer categories is better (prefer 1 over 4).

**Where:** `ClassificationEngine.swift`, `buildClassificationInstructions()` function (line 193).

**Changes:**
- Modify the instruction text
- Ensure `uncategorized` category is included in the category list sent to the model
- Update the `buildClassificationInstructions` unit test to match new text

**Acceptance criteria:**
- Prompt includes negative instruction for insufficient evidence
- `uncategorized` appears in the category list
- Existing tests updated and passing

**Confidence:** High

---

### M4: Add Confidence Field to `ArticleClassification`

**What:** Add a `confidence` field to the `@Generable` struct so the model self-assesses its classification confidence. This gives us a signal to gate on.

**Where:** `ClassificationEngine.swift`, `ArticleClassification` struct (line 12).

**Changes:**
```swift
@Generable
struct ArticleClassification {
  @Guide(
    description: "The most specific matching category labels...",
    .count(1...4))
  var categories: [String]

  @Guide(description: "A short stable kebab-case topic key...")
  var storyKey: String

  @Guide(description: "How confident you are in the classification, from 0.0 (guessing) to 1.0 (certain)")
  var confidence: Double
}
```

- Add `confidence` field to `ClassificationResult` DTO
- Pass confidence through `applyClassification` (store on Entry or just use for gating)

**Acceptance criteria:**
- `ArticleClassification` has a `confidence: Double` field with `@Guide`
- `ClassificationResult` carries the confidence value
- Build passes

**Confidence:** Medium — the `@Guide` for Double should work with `@Generable`, but self-assessed confidence from a 3B model may not be well-calibrated. This is the signal we'll gate on in M5.

---

### M5: Confidence Gate (Combining Keyword + LLM Signals)

**What:** Combine keyword match confidence (M2) and LLM self-assessed confidence (M4) to make the final classification decision. Route low-confidence results to "Uncategorized".

**Where:** `ClassificationEngine.swift`, after receiving the classification response, before creating `ClassificationResult`.

**Logic:**
1. Run keyword match → `[String: Double]` per category
2. Run LLM classification → categories + confidence
3. For each LLM-assigned category:
   - `finalConfidence = max(llmConfidence, keywordConfidence[category] ?? 0.0)`
   - If keyword confidence is high (≥ 0.8) for a category the LLM didn't pick → log it (future: consider overriding)
4. If `finalConfidence < threshold` → override to `[uncategorizedLabel]`
5. Threshold constant: start at `0.5`, tuneable

**Changes:**
- Integrate `keywordMatchConfidence()` call before LLM inference
- Combine signals after LLM response
- Add confidence threshold constant
- Log when confidence gate triggers and when keyword/LLM disagree
- Add unit tests for combined gating logic

**Acceptance criteria:**
- Keyword match boosts confidence for LLM-assigned categories
- Low overall confidence → "Uncategorized"
- High keyword confidence logged when LLM disagrees (diagnostic)
- Threshold is a named constant, easy to tune
- Tests cover: keyword-only high, LLM-only high, both low, both high

**Confidence:** Medium — logic is simple, threshold tuning is empirical.

---

### M6: Test `contentTagging` Adapter

**What:** Switch from `SystemLanguageModel.default` to `SystemLanguageModel(useCase: .contentTagging)` if the API exists in the current SDK. This adapter is specifically trained for classification/tagging tasks.

**Where:** `ClassificationEngine.swift`, model init.

**Changes:**
- Replace `SystemLanguageModel.default` with `SystemLanguageModel(useCase: .contentTagging)` (or equivalent API if the naming differs)
- If the API doesn't exist in the current SDK, document this and skip — no workaround needed
- Build verification must pass

**Acceptance criteria:**
- Build succeeds with the new model init (or reverted if API unavailable)
- Documented whether `contentTagging` adapter exists and if it changes behavior

**Confidence:** Low — the API may not exist in the current Xcode beta. If unavailable, skip this milestone entirely.

---

## 3. Risks

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| `contentTagging` adapter API doesn't exist | M6 skipped, no improvement from adapter | Medium | Skip M6, proceed with other milestones |
| Confidence from 3B model is poorly calibrated | Confidence gate is ineffective or too aggressive | High | Keyword match provides a second signal; start with low threshold (0.5); log values for tuning |
| Prompt changes degrade accuracy for currently-correct articles | Regression | Low | Test with diverse article set before/after; reclassify-all to compare |
| `@Generable` doesn't support `Double` field well | M4 blocked | Low | Fall back to `String` confidence like "high"/"medium"/"low" and map to numeric |
| Context window pressure from longer prompt | Less article body fits in context | Low | Keep prompt additions minimal; measure instruction character count before/after |
| Schema version bump (M2 keywords field) resets articles | User loses existing classifications | Low | Expected behavior per project rules; user re-syncs and reclassifies |

---

## 4. Confidence per Milestone

| Milestone | Confidence | Notes |
|---|---|---|
| M0: Replace default categories | **High** | Data-only change, straightforward |
| M1: Input validation gate | **High** | Simple conditional, no API risk |
| M2: Keyword match confidence | **High** | Pure string matching, schema change straightforward |
| M3: Prompt improvements | **High** | Pure text changes, testable |
| M4: LLM confidence field | **Medium** | `@Generable` + Double should work, calibration uncertain |
| M5: Confidence gate (combined) | **Medium** | Logic is simple, threshold tuning is empirical |
| M6: contentTagging adapter | **Low** | API availability unknown |

---

## 5. Quality Gates

### Before PR

1. **Build clean:** `bash .claude/scripts/test-all.sh` — zero errors, zero warnings
2. **Unit tests pass:** All existing + new tests green
3. **New tests cover:**
   - Empty article input gate (M1)
   - Keyword match confidence scoring (M2)
   - Updated prompt includes `uncategorized` and negative instruction (M3)
   - Combined confidence gate logic at threshold boundary (M5)
4. **Context budget check:** Measure instruction string length before/after prompt changes — must not exceed current budget significantly
5. **Manual smoke test:** User reclassifies a batch in Xcode and compares results

### Implementation Order

M0 → M1 → M2 → M3 → M4 → M5 → M6 (M0 first as foundation for all other changes; M6 last because it may not be available)
