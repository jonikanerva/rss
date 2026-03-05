# Decision Log: Apple Foundation Models Comparison

Date: 2026-03-04
Status: Comparison complete

## Runs compared

| Run | Model | Items | Fallback rate | Errors | Latency/item |
|-----|-------|-------|---------------|--------|--------------|
| run-010 | Ollama llama3.2:3b (4096 ctx) | 106 | 24.5% | 0 | ~10-17 sec |
| run-011 | Apple FM default (greedy) | 106 | 34.9% | 32 | ~1.2 sec |
| run-012 | Apple FM contentTagging (greedy) | 106 | 31.1% | 33 | ~0.8 sec |

## Key findings

### 1. Speed: Apple FM is 10x faster
- Apple FM default: median 1,062ms per item
- Apple FM contentTagging: median ~750ms per item
- Ollama llama3.2:3b: median ~12,000ms per item

### 2. Finnish language: Apple FM fails on ~30 items
- 30 of 106 items throw `unsupportedLanguageOrLocale` — all yle.fi Finnish articles
- Ollama handles Finnish fine (processes all 106 items)
- This accounts for the higher apparent fallback rate (34.9% includes errors)
- **On non-error items only**: Apple FM fallback rate drops to ~7% (5/74) — better than Ollama's 24.5%

### 3. Label quality comparison (74 non-error items)
- Exact label set match: 16/74 (21.6%)
- At least one label overlap: 60/74 (81.1%)
- Key difference: Apple FM uses fewer multi-label assignments (more single-label)

### 4. Label distribution (Apple FM default vs Ollama)

| Label | Ollama | Apple FM default | Apple FM contentTagging |
|-------|--------|-----------------|----------------------|
| technology | 62 | 25 | 73 |
| apple | 18 | 10 | 5 |
| gaming | 15 | 18 | 7 |
| ai | 18 | 12 | 60 |
| home_automation | 4 | 3 | 56 |
| world | 19 | 13 | 7 |
| other | 40 | 53 | 36 |
| tesla | 1 | 1 | 0 |
| playstation_5 | 2 | 0 | 6 |

### 5. contentTagging adapter is not suitable
- Over-assigns `home_automation` (56 vs expected ~4) and `ai` (60 vs expected ~18)
- Under-assigns `apple` (5 vs expected ~18) and `gaming` (7 vs expected ~15)
- The adapter seems biased toward broad tech categories, not our custom taxonomy

### 6. Apple FM default model qualitative observations
- **Better on gaming**: Scott Pilgrim, Pokémon, God of War correctly tagged (Ollama missed these)
- **Weaker on technology breadth**: Much less likely to add `technology` as a secondary label
- **Apple articles**: 8/14 correctly tagged `apple`, vs 14/14 with Ollama. Some Apple articles only get `technology`
- **Less multi-labeling overall**: Apple FM tends toward single categories, Ollama adds `technology` broadly

## Assessment

**Apple FM default model is very promising but has two blockers:**

1. **Finnish language not supported** — 30/106 items (28%) are Finnish and fail entirely. Need a fallback strategy (either skip classification or use a different model for Finnish content).

2. **Fewer multi-label assignments** — The model seems to pick a primary category and stop, while Ollama adds secondary categories like `technology`. This could be tuned with prompt changes.

**Apple FM advantages confirmed:**
- 10x faster inference
- Zero app size impact
- Constrained decoding (no JSON parsing failures in non-error items)
- Better gaming classification than Ollama

## Recommendation

**Use Apple Foundation Models as the primary classifier** for production, with these adaptations:

1. **Finnish fallback**: For articles where the model throws `unsupportedLanguageOrLocale`, either:
   - Classify based on feed source metadata only, OR
   - Mark as `world` based on the source being yle.fi (a Finnish news site)

2. **Prompt tuning**: Adjust instructions to encourage multi-label assignment (add "Assign all categories that clearly match, including broad categories like 'technology' alongside specific ones like 'apple'")

3. **Skip contentTagging adapter**: Use the default model — it performs better with custom categories.

4. **Next step**: Run a tuned prompt comparison and then proceed to manual review on the Apple FM predictions.
