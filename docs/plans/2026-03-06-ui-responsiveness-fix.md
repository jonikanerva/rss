# Plan: UI Scroll Bug + Main Thread Responsiveness

Date: 2026-03-06
Status: Draft
Owner: Agent

## Problems

### P1: Three-panel scroll bug
When clicking an article, columns 1 (sidebar) and 2 (entry list) scroll up and become stuck. Content is inaccessible.

**Root cause**: The detail column contains a VStack with a header + WKWebView (NSViewRepresentable). The VStack has no bounded height. NavigationSplitView columns share a layout context; when the detail column's content changes from a placeholder to the article VStack+WKWebView, the unbounded layout triggers a recalculation that disrupts scroll positions in all columns. Custom wrappers (VStack around List in sidebar, Group wrapper in entry list, conditional view swap in detail) make this worse.

### P2: App beachballs on startup and during sync
The UI is completely unresponsive during sync, classification, and grouping.

**Root cause**: All three engines (SyncEngine, ClassificationEngine, GroupingEngine) are `@MainActor @Observable` and execute ALL heavy work on the main thread:
- SyncEngine: SwiftData fetch/save on main
- ClassificationEngine: per-entry loop with HTML stripping (regex), language detection (NLLanguageRecognizer), Apple FM inference, SwiftData save -- ALL on main
- GroupingEngine: O(n^2) Jaccard string clustering + SwiftData I/O on main
- No Task priority tuning anywhere

## Plan

### Task 1: Vanilla SwiftUI three-panel layout (P1 fix)

**Goal**: Strip the NavigationSplitView to the simplest possible structure. No custom VStack wrappers, no conditional view swaps, no WKWebView sizing workarounds. Use only standard SwiftUI patterns.

**Changes**:

1. **Sidebar**: Make `List` the direct, only child of the sidebar column. Move "News" header and status into `Section` header within the List. Remove `.safeAreaInset`. Remove `.navigationTitle("")`.

2. **Entry list**: Make `List(selection:)` the direct, only child of the content column. Show empty state via overlay, not conditional content inside the List. Remove all Group/conditional wrappers.

3. **Detail column**: Replace the VStack+WKWebView approach entirely. Use a single `ScrollView` containing the header and article body rendered as SwiftUI `Text` (using AttributedString from HTML), OR keep WKWebView but wrap the entire detail in a plain SwiftUI view with no unbounded VStack. Key: the detail column content must be a single scrollable view, not a VStack mixing fixed and scrollable children.

   Simplest approach: Put everything (header + body) inside ONE ScrollView. Render body HTML via WKWebView with a fixed or measured height, or switch to SwiftUI-native rendering.

   **Decision**: Keep WKWebView (HTML rendering fidelity matters for RSS content with images/tables/embeds), but wrap detail column in a single view structure where the WKWebView fills the remaining space via GeometryReader or layout priority, clipped to bounds.

4. **Remove**: `columnVisibility` state, `.navigationSplitViewStyle(.balanced)`, `.frame(minWidth:minHeight:)` on NavigationSplitView. Use the simplest defaults. Add back min frame on WindowGroup in FeederApp.swift if needed.

**Acceptance**: Clicking any article does NOT shift scroll position of columns 1 or 2.

### Task 2: Move heavy work off main thread (P2 fix)

**Goal**: The three engines keep their `@MainActor @Observable` status for UI-facing state (isClassifying, progress counters, etc.) but move ALL compute and I/O to background tasks. The main thread only receives state updates.

**Pattern** (per Swift 6 concurrency rules):
```swift
@MainActor @Observable
final class ClassificationEngine {
    var isClassifying = false
    var classifiedCount = 0
    // ... UI state stays @MainActor

    func classifyUnclassified(in context: ModelContext) async {
        isClassifying = true
        // Gather input data on main (lightweight SwiftData read)
        let inputData = gatherInputs(context)

        // Heavy work on background
        let results = await Task.detached(priority: .utility) {
            // language detection, HTML strip, ML inference
            return processEntries(inputData)
        }.value

        // Apply results back on main (SwiftData writes)
        applyResults(results, to: context)
        isClassifying = false
    }
}
```

**Changes per engine**:

1. **SyncEngine**: Network calls already async (good). Move SwiftData batch fetch/persist into smaller main-actor hops. No change needed for network layer. Add `.utility` priority to backfill and content-fetch tasks.

2. **ClassificationEngine**:
   - Gather entry IDs + text on main (fast SwiftData read)
   - `Task.detached(priority: .utility)` for the per-entry loop: HTML strip, language detect, FM inference
   - Return classification results as Sendable array of structs
   - Apply results to SwiftData on main in a single batch

3. **GroupingEngine**:
   - Gather story keys on main (fast read)
   - `Task.detached(priority: .utility)` for Jaccard clustering (O(n^2) CPU)
   - Return cluster results as Sendable structs
   - Apply to SwiftData on main

4. **ContentView triggers**: Change `Task { await engine.work() }` to not block the onChange handlers. Engines manage their own background dispatch internally.

**Acceptance**: App remains responsive (no beachball) during sync, classification, and grouping. UI updates progressively.

## Implementation order

1. Task 1 first (UI fix) -- smaller change, immediately testable
2. Task 2 second (background work) -- larger refactor, requires careful concurrency

## Risks

- Task.detached + SwiftData: ModelContext is not Sendable. Must extract plain data before detaching and write back after. This is the correct pattern per Swift 6 rules.
- Apple Foundation Models session: need to verify if FM inference can run off MainActor. If not, use Task with .utility and yield periodically.
- WKWebView in detail: if we constrain it improperly it might not scroll its own content. Need to verify scrolling works after layout changes.
