# Research: Apple Foundation Models vs Ollama llama3.2:3b for Article Classification

Date: 2026-03-03
Owner: Repository Owner + Agent
Status: Draft

## Problem and users

- Our VISION.md already specifies "Uses built in Apple Foundation Models as the LLM" for production.
- The Ollama/llama3.2:3b feasibility spike validated that a ~3B parameter model can classify RSS articles into user-defined categories with a generic prompt.
- We need to determine whether Apple's on-device foundation model can match or exceed llama3.2:3b quality for our classification task, which would eliminate the need to bundle any model with the app.

## Key findings from WWDC25 sessions

### Apple's on-device model specs
- **3 billion parameters, quantized to 2 bits** — same parameter count as llama3.2:3b
- Available on **macOS 26, iOS, iPadOS, visionOS** — our target is macOS 26
- **Built into the OS** — zero app size impact, no model bundling
- **Works offline** — all processing on-device, data never leaves device
- **Optimized for**: summarization, extraction, **classification**, content tagging
- Has a dedicated **`contentTagging` adapter** trained specifically for tag generation, entity extraction, and topic detection

### Foundation Models framework capabilities (relevant to our task)

1. **Guided Generation (`@Generable` macro)**: Guarantees structurally correct output using constrained decoding. No JSON parsing failures. We define a Swift struct and the model generates an instance of it.

2. **Content Tagging Adapter** (`SystemLanguageModel(useCase: .contentTagging)`): A specialized adapter specifically trained for our exact use case. Can be combined with custom instructions and custom `@Generable` output types.

3. **Greedy sampling**: `GenerationOptions(sampling: .greedy)` gives deterministic output for the same prompt + session state. Same as our `temperature=0, seed=0` approach with Ollama.

4. **Context window**: Has limits — throws `exceededContextWindowSize` error if exceeded. We'd need to test how large the context window is and whether our full-content articles fit.

5. **Tool calling**: The model can autonomously call Swift functions — could be used for Feedbin API integration in the production app.

6. **Streaming**: Snapshot-based streaming with `PartiallyGenerated` types — natural SwiftUI integration for progressive UI updates.

### What the Swift API looks like for our use case

```swift
import FoundationModels

@Generable
struct ArticleClassification {
    @Guide(description: "Categories that match this article", .count(1...3))
    var categories: [CategoryLabel]
    
    @Guide(description: "A short stable kebab-case topic key for story grouping")
    var storyKey: String
}

@Generable
enum CategoryLabel {
    case technology, apple, tesla, ai, homeAutomation
    case gaming, gamingIndustry, playstation5, world, other
}

// Using the content tagging adapter
let session = LanguageModelSession(
    model: SystemLanguageModel(useCase: .contentTagging),
    instructions: """
        Categorize articles into user-defined categories.
        Only assign a category when the article content provides clear evidence for it.
        """
)

let response = try await session.respond(
    to: "title: \(article.title)\nbody: \(article.body)",
    generating: ArticleClassification.self
)
```

## Constraints and assumptions

1. **Requires macOS 26** — our vision targets macOS 26, so this is aligned.
2. **Requires Apple Intelligence-enabled hardware** — M1 or later Mac, 16GB+ RAM for best performance.
3. **Can't run from Python** — comparison test requires a Swift test harness.
4. **Model version changes with OS updates** — greedy sampling gives determinism within a version, but not across OS updates.
5. **Context window size is undocumented** — need to test empirically whether our full-content articles (up to ~16K chars / ~4K tokens) fit.
6. **Language support** — throws `unsupportedLanguageOrLocale` for unsupported languages. Our queue includes Finnish (yle.fi) articles. Need to test.

## Alternatives and tradeoffs

| Factor | Apple Foundation Models | Ollama llama3.2:3b |
|--------|------------------------|---------------------|
| App size impact | **Zero** (built into OS) | ~2GB model download |
| Deployment | Ships with macOS 26 | Bundle or require user install |
| Classification adapter | **`contentTagging` specialized** | Generic prompt only |
| Output reliability | **Constrained decoding** (zero parse failures) | JSON parsing with fallback heuristics |
| Swift integration | **Native** (`@Generable`, SwiftUI streaming) | Subprocess + JSON over HTTP |
| Offline | Yes | Yes (if model installed) |
| Determinism | Greedy sampling (per OS version) | seed=0, temp=0 (stable) |
| Context window | Unknown, needs testing | 4096 tokens (configurable) |
| Finnish language | Unknown, needs testing | Works (tested) |
| Speed | Unknown, likely optimized for Apple Silicon | ~8-15 sec/item on M-series |

## Comparison plan

### Phase 1: Build Swift test harness (can do now)
- Create a minimal Swift command-line tool or Xcode project
- Read the same `items.jsonl` queue
- Use the same `categories-v1.yaml` definitions
- Call Foundation Models with same prompt logic
- Write predictions to same JSONL format for comparison

### Phase 2: Run comparison on same dataset
- Process all 106 items from `data/review/current/items.jsonl`
- Use both default model and `contentTagging` adapter
- Record: predictions, latency per item, any errors (language, context window)
- Run with greedy sampling for determinism check

### Phase 3: Compare results
- Item-by-item label comparison vs llama3.2:3b predictions
- Agreement rate between models
- Use existing manual reviews (once done) as ground truth
- Compute same metrics: fallback rate, label distribution, F1 if ground truth available

## Evidence and source links

- WWDC25 "Meet the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2025/286/
- WWDC25 "Deep dive into the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2025/301/
- WWDC25 "Explore prompt design & safety for on-device foundation models": https://developer.apple.com/videos/play/wwdc2025/248/
- Apple Intelligence developer page: https://developer.apple.com/apple-intelligence/
- Product vision: `docs/vision/VISION.md` (line 63: "Uses built in Apple Foundation Models as the LLM")
- Current baseline: `artifacts/feasibility/run-010-llama3.2-3b-full-content/`

## Recommendation

**This is a strong GO for comparison testing.** The evidence strongly favors Apple Foundation Models for production:

1. The `contentTagging` adapter is literally built for our use case.
2. `@Generable` with constrained decoding eliminates all JSON parsing issues we've been working around.
3. Zero app size impact vs bundling a 2GB model.
4. Native Swift/SwiftUI integration is far cleaner than subprocess + HTTP.
5. Same ~3B parameter model scale, so quality should be comparable.

**Risks to test:**
- Finnish language support (our queue has Finnish articles from yle.fi)
- Context window size (can our 16K char articles fit?)
- Whether `contentTagging` adapter with custom categories matches our generic prompt quality

**Next step:** Build a Swift test harness that can process our existing `items.jsonl` and produce comparable predictions for side-by-side evaluation.
