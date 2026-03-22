# Code Quality Spike — Implementation Plan

Date: 2026-03-22
Branch: `worktree-chore-code-quality-spike`
Classification: MEANINGFUL (multi-file refactor, architecture compliance, test coverage)

## Objective

Bring the entire codebase to "premium" state before new feature work. Fix all architecture violations, remove dead code, eliminate code smells, extract testable pure logic, write comprehensive unit tests, and create a master test runner that gates all changes.

## Scope

In-scope:
- Dead code removal
- Two-layer architecture compliance (all writes through DataWriter)
- @Query predicate compliance (no Swift-side filtering)
- Code cleanup (stubs, force unwraps)
- Extract pure logic from engines into testable nonisolated functions
- Core engine unit tests (DataWriter, FeedbinClient, SyncEngine, ClassificationEngine)
- Master test runner script (gates all agent work before presenting to human)

Out-of-scope (future work):
- CI/CD pipeline (GitHub Actions)
- Integration/end-to-end tests
- FeedbinClient network mocking (test pure logic only)

## Tasks

### Task 1: Remove dead code — GroupingEngine + StoryGroup

**Files to delete:**
- `Feeder/Classification/GroupingEngine.swift`
- `Feeder/Models/StoryGroup.swift`

**Files to modify:**
- `Entry.swift` — `storyKey` is set by ClassificationEngine, keep it. Only StoryGroup references removed.
- `EntryDetailView.swift` — remove `siblings` parameter if StoryGroup references are gone
- `ContentView.swift` — remove any StoryGroup/siblings references
- Xcode project file — remove deleted files from build phases

**Risk:** LOW — code is confirmed never called.

### Task 2: Move CategoryManagementView writes to DataWriter

**DataWriter additions:**
```swift
func addCategory(label: String, description: String, parentLabel: String?, sortOrder: Int, systemPrompt: String?) throws
func deleteCategory(by label: String) throws
func updateCategorySortOrders(_ updates: [(label: String, sortOrder: Int)]) throws
func seedDefaultCategories(_ definitions: [CategoryDefinition]) throws
```

**CategoryManagementView changes:**
- Replace all `modelContext.insert/delete/save()` calls with `await dataWriter.method()`
- Access `DataWriter` via `@Environment` or injected dependency
- Wrap calls in `Task { }` for async bridge

**Risk:** MEDIUM — UI responsiveness may change. Verify UX stays snappy.

### Task 3: Replace Swift-side filtering with @Query predicates

**Approach:** Create `ChildCategoryList` sub-view with parameterized `@Query(filter: #Predicate { $0.parentLabel == parentLabel }, sort: \.sortOrder)`. Eliminates all Swift-side `.filter/.sorted` on @Query results.

**Affected files:**
- `ContentView.swift:246-247`
- `CategoryManagementView.swift:139-140, 171, 251, 265`

**Risk:** LOW — SwiftData predicates support simple equality and sort.

### Task 4: Remove navigateEntry() stub + soften force unwraps

**ContentView.swift:** Delete empty `navigateEntry(direction:)` and its keyboard handler calls.

**FeedbinClient.swift:** Replace 4 force unwraps with `guard let` + throw:
- Line 14: `data(using: .utf8)!`
- Line 95: `URLComponents(...)!`
- Lines 98, 121: `components.url!`

**Risk:** LOW.

### Task 5: Extract pure logic from engines

Extract embedded pure logic into `nonisolated` free functions or static methods, making them directly testable without actor/SwiftData dependencies.

**DataWriter.swift:**
- Extract `enforceDeepestMatch(labels:childrenByParent:)` from `applyClassification()`

**FeedbinClient.swift:**
- Extract `buildEntriesURL(base:page:perPage:since:)` — URL construction
- Extract `parseLinkHeader(_:)` — Link header → hasNextPage
- Extract `mapHTTPStatus(_:)` — status code → FeedbinError?

**SyncEngine.swift:**
- `articleKeepDays` and `maxArticleAge` already exist as computed properties — verify testability

**ClassificationEngine.swift:**
- `detectLanguage(_:)` and `normalizeStoryKey(_:)` already nonisolated — already testable
- Extract `buildInstructions(from:)` if not already accessible
- Extract `filterValidLabels(labels:validSet:)` from classification flow

**Risk:** LOW — pure refactoring, no behavior change.

### Task 6: Write core engine unit tests

Using Swift Testing framework (`@Test` macro), matching existing test patterns in `FeederTests.swift`.

**High-priority tests (most bug-prone):**

| Function | Test Cases |
|----------|-----------|
| `enforceDeepestMatch` | Parent stripped with child, parent kept alone, multi-child, cross-parent, empty→"other" |
| `normalizeStoryKey` | Kebab-case, special chars, length truncation, empty→"story-unknown" |
| `stripHTMLToPlainText` | Nested tags, all 6 entities, whitespace collapse, empty |
| `formatEntryDate` | Today, yesterday, weekday, ordinal suffixes (1st/2nd/3rd/11th/21st) |
| `detectLanguage` | English, Finnish, empty, mixed |
| `buildInstructions` | Hierarchical indent, descriptions, empty categories |
| `filterValidLabels` | Valid, invalid, mixed, empty→"other" |

**Medium-priority tests:**

| Function | Test Cases |
|----------|-----------|
| `buildEntriesURL` | Pagination, since parameter, query encoding |
| `parseLinkHeader` | Has next, no next, nil |
| `mapHTTPStatus` | 200→nil, 401→unauthorized, 429→rateLimited, 500→httpError |
| `articleKeepDays` | Default 7, custom UserDefaults value |
| `ArticleBlock.classificationText` | All block types, empty |
| `ArticleBlock` JSON roundtrip | Encode/decode all types |

**Estimated test count:** ~40-50 tests total (21 existing + ~25 new).

**Risk:** LOW — testing pure functions, no mocking needed.

### Task 7: Master test runner script

**New file:** `.claude/scripts/test-all.sh`

```bash
#!/usr/bin/env bash
# Master test runner — must pass before presenting changes to human.
# Runs: build verification + unit tests + UI smoke tests
# Exit code 0 = all green, non-zero = blocked

set -euo pipefail

# Phase 1: Build (zero warnings, zero errors)
# Phase 2: Unit tests (FeederTests)
# Phase 3: UI smoke tests (FeederUITests)
# Summary: pass/fail counts
```

Features:
- Calls `build-for-testing.sh` once (shared derived data)
- Runs `FeederTests` via `xcodebuild test-without-building`
- Runs `FeederUITests` via existing `ui-smoke.sh` (with `BUILD_FIRST=0`)
- Aggregates results, exits non-zero on any failure
- Stores all xcresult bundles in `artifacts/local/xcresult/`

**Convention:** All agents MUST run `bash .claude/scripts/test-all.sh` and get exit code 0 before presenting changes to a human.

### Task 8: Build verification + artifacts

- Run `test-all.sh` — must pass
- Commit plan to `docs/plans/`
- Update `docs/STATUS.md` and `docs/plans/NEXT-ACTIONS.md`

## Execution Order

```
1 (dead code) → 4 (stubs/unwraps) → 5 (extract pure logic) → 3 (query predicates)
→ 2 (DataWriter refactor) → 6 (unit tests) → 7 (master runner) → 8 (verify + deliver)
```

Rationale:
- Task 1 first — remove noise, simplify codebase
- Task 4 — quick wins, no dependencies
- Task 5 — extract testable functions before writing tests
- Task 3 — @Query compliance (simpler than Task 2)
- Task 2 — biggest refactor (DataWriter changes)
- Task 6 — tests written against clean, extracted functions
- Task 7 — master runner wraps everything
- Task 8 — final gate

Build check after each task to ensure incremental correctness.

## Success Criteria

- [ ] Zero dead code files (GroupingEngine, StoryGroup removed)
- [ ] Zero architecture violations (no MainActor writes outside DataWriter)
- [ ] Zero Swift-side @Query filtering
- [ ] Zero empty stub methods
- [ ] Zero force unwraps in production code (previews OK)
- [ ] Pure logic extracted from all 4 engines
- [ ] ~25+ new unit tests covering extracted logic
- [ ] Master test runner script (`test-all.sh`) exits 0
- [ ] Build clean: zero warnings, zero errors
- [ ] All existing tests still pass
