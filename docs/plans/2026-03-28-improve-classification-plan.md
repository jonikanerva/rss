# Plan: Improve Apple FM Classification Accuracy

**Date:** 2026-03-28
**Research:** [docs/research/2026-03-28-improve-classification-accuracy.md](../research/2026-03-28-improve-classification-accuracy.md)

---

## 1. Scope

Improve the accuracy of on-device article classification using Apple Foundation Models. The model currently misclassifies articles — assigning wrong categories or classifying completely empty articles. This plan addresses the problem through five targeted changes, all within the existing Apple FM pipeline.

**In scope:**
- Input validation gate for completely empty articles (no title AND no body)
- `contentTagging` adapter (if available in SDK)
- Prompt engineering improvements
- Confidence field via `@Guide` on `ArticleClassification`
- Confidence gate routing low-confidence results to "Uncategorized"

**Out of scope:** OpenAI/cloud fallback, NLEmbedding ensemble, LoRA adapter training.

---

## 2. Milestones

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

### M2: Test `contentTagging` Adapter

**What:** Switch from `SystemLanguageModel.default` to `SystemLanguageModel(useCase: .contentTagging)` if the API exists in the current SDK. This adapter is specifically trained for classification/tagging tasks.

**Where:** `ClassificationEngine.swift`, line 101.

**Changes:**
- Replace `SystemLanguageModel.default` with `SystemLanguageModel(useCase: .contentTagging)` (or equivalent API if the naming differs)
- If the API doesn't exist in the current SDK, document this and skip — no workaround needed
- Build verification must pass

**Acceptance criteria:**
- Build succeeds with the new model init (or reverted if API unavailable)
- Documented whether `contentTagging` adapter exists and if it changes behavior

**Confidence:** Low — the API may not exist in the current Xcode beta. If unavailable, skip this milestone entirely.

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

### M5: Confidence Gate

**What:** Route low-confidence classifications to "Uncategorized" instead of accepting a likely-wrong category.

**Where:** `ClassificationEngine.swift`, after receiving the classification response (line 151), before creating `ClassificationResult`.

**Changes:**
- Add a confidence threshold constant (start with `0.5` — tuneable)
- If `classification.confidence < threshold`, override labels to `[uncategorizedLabel]`
- Log when confidence gate triggers for debugging/tuning
- Add unit test for the gating logic

**Acceptance criteria:**
- Classifications with confidence below threshold → "Uncategorized"
- Classifications with confidence at or above threshold → normal flow
- Threshold is a named constant, easy to tune
- Existing tests pass, new gate test added

**Confidence:** Medium — the right threshold value will need empirical tuning. Start conservative (0.5) and adjust based on real-world results.

---

## 3. Risks

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| `contentTagging` adapter API doesn't exist | M2 skipped, no improvement from adapter | Medium | Skip M2, proceed with other milestones |
| Confidence from 3B model is poorly calibrated | Confidence gate is ineffective or too aggressive | High | Start with low threshold (0.5), log confidence values for tuning, make threshold easily adjustable |
| Prompt changes degrade accuracy for currently-correct articles | Regression | Low | Test with diverse article set before/after; reclassify-all to compare |
| `@Generable` doesn't support `Double` field well | M4 blocked | Low | Fall back to `String` confidence like "high"/"medium"/"low" and map to numeric |
| Context window pressure from longer prompt | Less article body fits in context | Low | Keep prompt additions minimal; measure instruction character count before/after |

---

## 4. Confidence per Milestone

| Milestone | Confidence | Notes |
|---|---|---|
| M1: Input validation gate | **High** | Simple conditional, no API risk |
| M2: contentTagging adapter | **Low** | API availability unknown |
| M3: Prompt improvements | **High** | Pure text changes, testable |
| M4: Confidence field | **Medium** | `@Generable` + Double should work, calibration uncertain |
| M5: Confidence gate | **Medium** | Logic is simple, threshold tuning is empirical |

---

## 5. Quality Gates

### Before PR

1. **Build clean:** `bash .claude/scripts/test-all.sh` — zero errors, zero warnings
2. **Unit tests pass:** All existing + new tests green
3. **New tests cover:**
   - Empty article input gate (M1)
   - Updated prompt includes `uncategorized` and negative instruction (M3)
   - Confidence gate logic at threshold boundary (M5)
4. **Context budget check:** Measure instruction string length before/after prompt changes — must not exceed current budget significantly
5. **Manual smoke test:** User reclassifies a batch in Xcode and compares results

### Implementation Order

M1 → M3 → M4 → M5 → M2 (M2 last because it may not be available, and the other milestones provide value regardless)
