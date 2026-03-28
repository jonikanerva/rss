# Research: Improving Article Classification Accuracy

**Date:** 2026-03-28
**Status:** Complete — ready for planning

---

## 1. Problem

Apple Foundation Models (3B on-device LLM) produces frequent misclassifications in Feeder's article categorization pipeline:

- **Assigns categories despite empty text fields** — when `plainText` is empty or minimal, the model still confidently picks categories based on insufficient evidence.
- **Content mismatch** — model assigns categories that don't match the actual article content.
- **Comparison with OpenAI** — the same articles fed to GPT models produce significantly more accurate classifications.

The current implementation (`ClassificationEngine.swift`) uses `SystemLanguageModel.default` with `@Generable` structured output and greedy sampling. While the structured output mechanism works reliably (no parse errors), the model's reasoning and classification accuracy are insufficient for the task.

---

## 2. Constraints

| Constraint | Detail |
|---|---|
| **Model size** | Apple FM is ~3B parameters, 2-bit quantized — far smaller than cloud models (GPT-4o: hundreds of billions) |
| **Context window** | 4096 tokens total (input + output + schema). Current budget: ~3800×4 chars for instructions + article |
| **Language support** | Only 9 languages (EN, FR, DE, IT, PT-BR, ES, JA, KO, ZH-CN). Finnish NOT supported |
| **No logprobs** | Apple FM provides no confidence scores or token probabilities |
| **Privacy** | On-device is a key selling point; cloud fallback must be opt-in |
| **Offline** | App must work offline; cloud-only is not acceptable |
| **Dynamic categories** | Users can create/edit categories — pre-trained static classifiers won't adapt |
| **Architecture** | All classification runs through `DataWriter` on background thread; no MainActor writes |

---

## 3. Alternatives

### Alternative A: Optimize Apple FM Usage (Quick Wins)

**Description:** Improve classification within the existing Apple FM pipeline without adding new dependencies.

**Sub-options:**

1. **Use `contentTagging` adapter** — Apple provides a pre-trained adapter specifically for classification/tagging tasks. Current code uses `SystemLanguageModel.default`; switching to `SystemLanguageModel(useCase: .contentTagging)` may significantly improve accuracy for categorization.

2. **Add input validation gate** — Skip classification (assign "Uncategorized") when `title + plainText` is below a minimum threshold (e.g., < 50 characters). This directly addresses the "classifies empty content" problem.

3. **Improve prompt engineering:**
   - Shorten category descriptions to conserve context for article content
   - Add negative instructions: "If the article content is empty or too short to classify, return only 'uncategorized'"
   - Add 1-2 few-shot examples in the instructions (space permitting given 4096 token limit)
   - Reorder/prioritize categories to reduce ambiguity

4. **Add `@Guide` confidence field** to `ArticleClassification` struct — request the model to self-assess confidence, then route low-confidence results to "Uncategorized" instead of a wrong category.

**Pros:**
- No new dependencies
- Fully on-device, no privacy concerns
- Fast to implement
- Maintains offline capability

**Cons:**
- Fundamental model capability ceiling (~3B params)
- `contentTagging` adapter is underdocumented; effectiveness unknown
- Self-assessed confidence from small models is poorly calibrated
- Few-shot examples eat into the already-tight context window

**Estimated effort:** Small (1-2 days)

---

### Alternative B: Hybrid Architecture — Apple FM + OpenAI API Fallback

**Description:** Keep Apple FM as the primary classifier; add OpenAI API as an optional cloud fallback for cases where Apple FM is unavailable, unsupported language, or low confidence.

**Architecture:**
```
Article → Input Validation Gate
  ├── Too short/empty → "Uncategorized" (no LLM call)
  └── Sufficient content
        → Apple FM Classification
            ├── Success + high confidence → Use result
            └── Failure / low confidence / unsupported language
                  → OpenAI API (if user opted in)
                      ├── Success → Use result
                      └── Failure → "Uncategorized"
```

**Implementation details:**
- **Model choice:** GPT-4.1 Nano ($0.10/1M input tokens) — designed for classification/extraction
- **Batch API** for non-realtime classification: 50% cost reduction, 24h processing window
- **Structured Outputs** (`json_schema` + `strict: true`) — analogous to `@Generable`
- **User opt-in:** Settings toggle for cloud classification; default OFF
- **Minimal data sent:** Title + first ~200 words only
- **Cost:** ~$0.50-1.00/month for typical RSS usage (500 articles/day)

**Pros:**
- Dramatically better accuracy for edge cases
- Covers unsupported languages (Finnish, etc.)
- Works when Apple FM is unavailable
- Low cost
- Maintains on-device default for privacy

**Cons:**
- New dependency (OpenAI API key required)
- Privacy concern for privacy-conscious users (mitigated by opt-in)
- Requires network for fallback
- API key management complexity
- Ongoing operational cost (though minimal)

**Estimated effort:** Meaningful (3-5 days)

---

### Alternative C: NLEmbedding-Based Pre-classifier

**Description:** Use Apple's NaturalLanguage framework (`NLEmbedding`) as a fast, zero-shot pre-classifier. Compute semantic similarity between article text and category descriptions to handle clear-cut cases without any LLM call.

**How it works:**
1. Compute sentence embeddings for each category description (cached)
2. For each article, compute embedding of title + first N words
3. Calculate cosine similarity against all category embeddings
4. If top match exceeds threshold → assign directly (skip LLM)
5. If below threshold → pass to Apple FM (or cloud fallback)

**Pros:**
- Extremely fast (no LLM inference)
- No context window limits
- Reduces Apple FM calls by estimated 30-50%
- Battery efficient
- No external dependencies

**Cons:**
- Lower accuracy than LLM for nuanced/ambiguous articles
- Limited language support in NLEmbedding
- Threshold tuning required
- Can't handle multi-label classification well
- Category descriptions must be carefully crafted for embedding space

**Estimated effort:** Meaningful (2-3 days)

---

### Alternative D: Custom LoRA Adapter Training

**Description:** Train a custom LoRA adapter using Apple's TAMM toolkit, specialized for Feeder's categorization task.

**Pros:**
- Can approach GPT-4 accuracy for specific tasks
- Runs fully on-device
- Tailored to Feeder's category taxonomy

**Cons:**
- Requires 100-1000+ training examples per category
- ~160MB per adapter
- Must retrain for each macOS version
- Requires special Apple entitlement
- 32GB+ RAM for training
- Dynamic categories would require retraining
- Massive development effort

**Estimated effort:** Large (weeks), not recommended for current phase

---

## 4. Evidence

### Apple FM Benchmarks
- Apple's own tech report shows the 3B on-device model trails GPT-4o significantly in reasoning and classification tasks ([Apple FM Tech Report 2025](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025))
- Human evaluations rank Apple FM well below GPT-4o in overall text quality ([The Decoder benchmarks](https://the-decoder.com/apples-new-ai-benchmarks-show-its-models-still-lag-behind-leaders-like-openai-and-google/))

### `contentTagging` Adapter
- Apple provides pre-built adapters including `contentTagging` for classification tasks ([WWDC25 Session 301](https://developer.apple.com/videos/play/wwdc2025/301/))
- Current codebase does NOT use this adapter — uses base `SystemLanguageModel.default`

### OpenAI Classification Cost
- GPT-4.1 Nano: $0.10/1M input, $0.40/1M output ([OpenAI Pricing](https://pricepertoken.com/pricing-page/provider/openai))
- 500 articles/day × 500 tokens/article = 250K input tokens/day = $0.025/day = ~$0.75/month
- Batch API: 50% discount → ~$0.38/month

### Empty Content Problem
- Current code (`DataWriter.swift` lines 280-292): empty `plainText` is passed to classification as-is
- No minimum content threshold exists
- Model receives `"title: Some Title\ncontent: "` with empty body → guesses category from title alone or hallucinate

### LLM Confidence Calibration
- Research shows small LLMs' self-assessed confidence is poorly calibrated: 66.7% of errors occur at >80% stated confidence ([LLM Classifier Confidence Scores](https://aejaspan.github.io/posts/2025-09-01-LLM-Clasifier-Confidence-Scores))
- Apple FM provides no logprobs API, making external confidence measurement impossible

### Third-Party Compatibility Libraries
- **AnyLanguageModel** (Hugging Face): Drop-in replacement for Apple FM that supports OpenAI, Anthropic, Ollama backends ([HuggingFace blog](https://huggingface.co/blog/anylanguagemodel))
- **OpenFoundationModels**: 100% API-compatible with Apple FM, multi-provider support ([Swift Forums](https://forums.swift.org/t/openfoundationmodels-apple-compatible-foundation-models-api-with-multi-provider-support/82168))

---

## 5. Unknowns

| Unknown | Impact | How to resolve |
|---|---|---|
| **`contentTagging` adapter effectiveness** | Could solve the problem with zero new code | Quick experiment: swap model init, test with known-bad articles |
| **Apple FM confidence via `@Guide`** | Could enable smart fallback routing | Prototype: add confidence field, measure calibration |
| **NLEmbedding accuracy for our categories** | Determines viability of Alternative C | Benchmark: embed current categories, test against 50 articles |
| **OpenAI Structured Outputs with @Generable-like schema** | Determines how much code sharing is possible | Prototype the DTO layer |
| **User willingness to use cloud classification** | Determines if Alternative B is worth building | Ask/survey users |

**Biggest risk:** The `contentTagging` adapter might not exist in the current beta or might not meaningfully improve accuracy. If quick wins (Alternative A) don't move the needle, we'll need the full hybrid architecture (Alternative B), which is significantly more work.

---

## 6. Recommendation

**Evidence is sufficient to plan.** Recommended approach is a **phased strategy**:

### Scope: Improve Apple FM Classification Accuracy

1. Add input validation gate — only for completely empty articles (no title AND no body)
2. Test `contentTagging` adapter (if available in current SDK)
3. Improve prompt engineering: tighten category descriptions, add negative instructions for ambiguous cases
4. Add confidence field to `ArticleClassification` via `@Guide`
5. Add confidence gate: route low-confidence results to "Uncategorized"

NLEmbedding (Alternative C) is not recommended as a classification signal due to poor accuracy (~50-65%) and limited language support (no Finnish). Hybrid cloud fallback (Alternative B) is out of scope for this iteration.

### Additional Research: Ensemble Approach Evaluated and Rejected

An ensemble approach combining keyword match confidence + NLEmbedding similarity + LLM confidence was evaluated. Conclusion: **not recommended** because:
- NLEmbedding zero-shot accuracy is only ~50-65%, too noisy to be a useful ensemble member
- Cosine similarity scores cluster in 0.5-0.85 range with poor discriminative power
- NLEmbedding supports only 7 languages (no Finnish)
- No Apple framework needed for ensemble math — simple weighted average suffices
- Core ML/Create ML ensemble would require training data we don't have (cold start problem)
- Better ROI comes from improving the LLM signal itself + simple input/output gates
