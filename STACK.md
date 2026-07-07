# STACK.md — Feeder (Swift 6 / SwiftUI / macOS)

> Strict Swift 6 + SwiftUI macOS app. SwiftData persistence behind a background actor, Feedbin sync, on-device or user-chosen cloud classification. Apple frameworks only.

---

## 0. Project shape

- **Shape:** UI app (macOS / SwiftUI). Native Xcode project: `Feeder.xcodeproj`.
- **Critical execution path:** the main actor / UI thread (one display frame).
- **Applicable states:** every user-visible surface handles awaiting-first-data (loading), success, empty, degraded, offline, error, and permission-blocked (when applicable), plus product-specific states from `VISION.md`.

### Repository layout & layer convention

Feeder maps the doctrine's interface / domain / infrastructure layers onto a two-layer runtime shape:

- **Interface** (MainActor, read-only) — SwiftUI views in `Feeder/Views/` read via `@Query` with SQLite-level predicates (never filter results in Swift). `SyncEngine` and `ClassificationEngine` are `@Observable` for progress display only: zero `ModelContext`, all writes delegated to `DataWriter`.
- **Domain** (pure, `nonisolated`) — stateless helpers in `Feeder/Helpers/` (`stripHTMLToPlainText`, `formatEntryDate`, `detectLanguage`, `EntryFormatting`, `HTMLToBlocks`). Zero side effects; same input, same output; reusable from migration closures and tests.
- **Infrastructure** (background actors) — `DataWriter` (`@ModelActor`; owns `ModelContext`; ALL persistence writes; pre-computes display fields at write time) and `FeedbinClient` (`actor`; all HTTP requests). Never on MainActor.

**Actor boundaries:**

- DTOs crossing actors are `nonisolated struct` + `Sendable`.
- `@Model` objects never cross actor boundaries — pass `PersistentIdentifier` or DTOs.
- `DataWriter` init happens on a background thread.

**Why this matters:**

| Rule                                       | Reason                                                       |
| ------------------------------------------ | ------------------------------------------------------------ |
| No `ModelContext` on MainActor for writes  | `save()` triggers `@Query` re-evaluation and list re-render  |
| No computed filters on `@Query` results    | O(n) filter on every update defeats lazy rendering           |
| No expensive computation during rendering  | Calendar, regex, loops block MainActor = visible lag         |

---

## 1. Language & Runtime

- **Primary language:** Swift 6.1
- **Strictness mode:** `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. No new warnings; no `@preconcurrency` ratchet-loosening.
- **Target runtime:** macOS 26+
- **Minimum runtime version:** macOS 26.0 (no back-deployment, no `#available` for older OSes)
- **Package manager:** Swift Package Manager (`Package.resolved`)
- **Lockfile:** `Feeder.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- **Dev-environment provisioning:** Xcode 26+; everything else is driven through `make` (§3). No additional toolchain files.

---

## 2. Frameworks

| Concern             | Framework / library                                                            | Notes                                                                                          |
| ------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| UI / view layer     | SwiftUI                                                                        | AppKit only as a wrapped adapter                                                               |
| Design language     | macOS system components, system colors / fonts / materials                     | No custom chrome; see §11                                                                      |
| State / observation | Observation (`@Observable`, `@State`, `@Bindable`, `@Environment`)             | No `ObservableObject` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` for new code |
| Concurrency         | async / await, `AsyncSequence`, actors, structured concurrency                 | Full prohibition list in §7                                                                    |
| Navigation          | `NavigationSplitView`, `NavigationStack`                                       | No `NavigationView`                                                                            |
| Networking          | `URLSession` async / await                                                     |                                                                                                |
| Persistence         | SwiftData (`@Model`, `ModelContainer`, `@Query`) via `DataWriter` (`@ModelActor`) | See §5                                                                                      |
| Feedbin sync        | Custom `FeedbinClient` (`actor`)                                               | The only ingest source (`VISION.md → Non-Goals`)                                               |
| Classification      | Apple Foundation Models (on-device); OpenAI API (optional, user-supplied key)  | Both first-class; the user chooses (`VISION.md → Core Principles`)                             |
| Localization        | None — English-only UI in MVP                                                  |                                                                                                |
| Logging             | `os.Logger` per subsystem / category; `OSSignposter` for hot paths             | No `print()` in shipped code                                                                   |
| Telemetry           | None                                                                           | No third-party analytics, no crash reporter                                                    |
| Testing             | Swift Testing (`@Test`, `@Suite`, `#expect`); XCTest / XCUITest for end-to-end UI |                                                                                             |
| Formatting          | `swift-format` with repo `.swift-format`                                       | No SwiftLint                                                                                   |
| Build               | Xcode 26+, Swift 6 language mode, complete strict concurrency                  |                                                                                                |

---

## 3. Build & verify commands

| Variable         | Command                                                |
| ---------------- | ------------------------------------------------------ |
| `$FORMAT_CMD`    | `make lint-fix`                                        |
| `$LINT_CMD`      | `make lint`                                            |
| `$BUILD_CMD`     | `make build`                                           |
| `$TEST_CMD`      | `make test`                                            |
| `$VERIFY_CMD`    | `make test-all` (lint → build → unit tests)            |
| `$TEST_FULL_CMD` | `make test-full` (lint → build → unit + UI tests)      |
| `$PERF_CMD`      | `make perf` (local perf regression suite; see §4)      |

The `Makefile` at the repository root is the single source of truth for these commands. Never invoke `swift-format`, `xcodebuild`, or `xcrun` directly from commits, CI, or agent scripts — always go through `make`.

---

## 4. Performance budgets

- **UI frame budget:** 16 ms baseline; 8.3 ms on ProMotion displays.
- **Cold start:** < 2 s on supported Macs.
- **Memory ceiling:** < 500 MB resident during normal browsing.
- **Article list scroll:** 120 fps achievable on ProMotion.
- **Sync / classification:** background work must not block the UI; long-running classification batches are cancellable and yield cooperatively.

Profile before optimizing. Stay inside these budgets unless a measurement-backed Intentional Divergence (§14) is recorded.

**Hot-path gate:** if a diff touches the hot path (`ContentView`, `EntryRowView`, `EntryDetailView`, `DataWriter` queries, `UnreadCountsSnapshot`, or signpost-bounded paths), run `$PERF_CMD` — it must pass without regression against the baselines in `Tests/PerfBaselines/` (see `Tests/PerfBaselines/README.md`; refresh with `make perf-record-baseline` only when a change is intentionally accepted).

---

## 5. Persistence shape

- **Storage primitive:** SwiftData (`@Model`, `ModelContainer`, `@Query`).
- **Writes:** ALL writes go through `DataWriter` (`@ModelActor`). No `ModelContext` on MainActor (§0).
- **Persisted entities:** declared by `VISION.md → Persistence and Privacy Posture`.
- **Schema versioning:** SwiftData first-party migration. Every shipped schema shape is a `VersionedSchema` (e.g. `FeederSchemaV1`). `FeederMigrationPlan: SchemaMigrationPlan` lists the versions in order plus the stages between them. The `ModelContainer` is opened with the plan so SwiftData runs the right stage at launch. **Prefer lightweight stages** (`.lightweight(fromVersion:toVersion:)`) for additive / removal-only changes — no data movement needed. **Use custom stages** (`.custom(fromVersion:toVersion:willMigrate:didMigrate:)`) when a denormalized display field needs recomputing or when data has to be transformed. **No auto-wipe on schema change.** User folders, categories (with `displayName`, `categoryDescription`, `keywords`, `sortOrder`), classified entries (`primaryCategory`, `primaryFolder`), and feeds must survive every schema bump.
- **Pre-computed display fields:** `DataWriter` pre-computes `plainText`, `formattedDate`, `formattedPublishedTime`, `primaryCategory`, `primaryFolder`, `displayDomain`, `summaryPlainText`, `articleBlocksData` at write time. **Any future schema change that touches the inputs to these fields requires a custom migration stage that recomputes them** so older rows render consistently with newly synced rows. The pure helpers in `Helpers/EntryFormatting.swift` and `Helpers/HTMLToBlocks.swift` are `nonisolated` and reusable from inside `willMigrate` / `didMigrate` closures.
- **Migration stages run inside the container open**, not through `DataWriter`. They receive a raw `ModelContext`, which is the documented Apple pattern and an intentional, bounded exception to "all writes through `DataWriter`" (§0) — migration stages only.
- **Forbidden persistence:** anything declared forbidden in `VISION.md → Persistence and Privacy Posture`.

---

## 6. Approved dependencies

Default answer to "should we add a library?" is **no** — especially for what Apple frameworks already solve. A new third-party SPM dependency requires an entry in this table **before** it lands in `Package.resolved`.

| Dependency                       | Version | Why it earns its place | Approver | Date |
| -------------------------------- | ------- | ---------------------- | -------- | ---- |
| _(none — Apple frameworks only)_ | —       | —                      | —        | —    |

---

## 7. Stack-specific reject-list additions

Hard rules for this stack; `/codereview` enforces every entry on every PR.

**Concurrency — prohibited pattern → replacement:**

| Prohibited                     | Replacement                           |
| ------------------------------ | ------------------------------------- |
| `DispatchQueue` / GCD          | `Task {}`, `async let`, `TaskGroup`   |
| `OperationQueue`               | `TaskGroup`                           |
| `NSLock` / semaphores          | `actor` isolation                     |
| `Timer.scheduledTimer`         | `Task.sleep(for:)` loop               |
| Completion handlers            | `async` functions                     |
| `Combine` for async            | `async` / `await`, `AsyncSequence`    |
| `withCheckedContinuation`      | Native async API or redesign          |
| `[weak self]` in Task closures | Structured concurrency                |

**Further reject-list entries:**

- `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `@Published` in new code — Observation framework only.
- `NavigationView` — `NavigationSplitView` / `NavigationStack` only.
- `ModelContext` on MainActor for writes — all writes through `DataWriter` (§0, §5).
- Filtering `@Query` results in Swift — push predicates to SQLite via the `@Query` predicate.
- `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `MainActor.assumeIsolated` without an inline-justified, audited comment explaining why no safe alternative exists.
- Expensive work in `body` — no regex, loops, or Calendar math during view rendering (§0, §4).
- `print()` in shipped code; `os.Logger` lines that interpolate user-derived values without `.private` (§8).
- `AnyView`, broad type erasure, reflection tricks unless there is a measured benefit.
- Force-unwraps (`!`) and `try!` outside tests and `#Preview`.
- `var` where `let` suffices.
- `TODO`, `FIXME`, `HACK`, or commented-out code in a shipped diff.
- Persisting or computing with local-time / calendar-component values instead of a `Date` instant; manual UTC-offset arithmetic; a `DateFormatter` / `Calendar` without an explicit `timeZone` in logic (§10; the pre-computed display-string fields are a documented divergence, §14).
- Custom controls where a standard macOS component exists; private API calls; third-party UI frameworks (§11).
- New SwiftPM packages without a §6 entry approved in advance.

---

## 8. Logging & privacy

- **Logger:** `os.Logger` per subsystem / category; `OSSignposter` for hot-path measurement. Log significant state changes only.

```swift
// In @MainActor files (default isolation):
private let logger = Logger(subsystem: "com.feeder.app", category: "ModuleName")

// In non-MainActor actors:
actor FeedbinClient {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")
}
```

- **PII redaction:** use `os.Logger` `.private` interpolation for any value derived from user data (article URLs, feed URLs, API keys, classification prompts).
- **Crash reporter:** none. No Sentry / Crashlytics / equivalent.
- **Privacy declaration:** keep `PrivacyInfo.xcprivacy` accurate. Every required-reason API call is declared.
- **Secrets:** never in the repo. Configuration via the macOS Keychain or `.env` (gitignored). Agents never read `.env` files (enforced by a settings hook).

---

## 9. Background & lifecycle

- **Allowed background work:** in-process background actors (`DataWriter`, `FeedbinClient`); periodic Feedbin sync via a cancellable `Task.sleep(for:)` loop; classification batches that are cancellable and yield cooperatively. All background work stops when the app quits.
- **Forbidden background work:** launch agents, daemons, login items, or any execution outside the app's lifetime; polling loops that cannot be cancelled; background work that blocks or contends with the MainActor (§4).

---

## 10. Time & timezones

UTC everywhere internally, converted only at the boundary (`CLAUDE.md → Time`). Concrete mechanics:

- **Internal representation:** all timestamps in logic, SwiftData persistence, caches, and logs are `Date` instants. Canonical timeline ordering (`VISION.md → Core Principles`) sorts on `Date`, never on formatted strings.
- **Boundary conversion:** inbound Feedbin timestamps parse to `Date` immediately (`ISO8601DateFormatter`, GMT by default); user-facing values convert at the last moment via `Text(date, format:)` / `.formatted(...)` or a `DateFormatter` / `Calendar` with an explicit `timeZone`.
- **Banned:** storing or computing with calendar components or local-time strings in logic; manual UTC-offset arithmetic; `DateFormatter` / `Calendar` without an explicit `timeZone` outside the display boundary. *Documented exception:* the pre-computed display-string fields `formattedDate` / `formattedPublishedTime` (§5) are an Intentional Divergence (§14) — they are display artifacts, never inputs to logic or ordering.
- **Tests:** inject a fixed `Date` rather than reading `Date.now`; no timezone-dependent assertions.

---

## 11. Design guidelines & UX thresholds

- **Design authority:** Apple Human Interface Guidelines (macOS). The app must look and feel like Apple built it — no custom design language.
  - Standard SwiftUI components (`List`, `NavigationSplitView`, `Table`, `Form`, `Toggle`, …); no custom controls when Apple provides an equivalent.
  - System colors (`Color.primary`, `Color.secondary`, `.background`) and system fonts (`.body`, `.headline`, `.caption`); dark mode honoured.
  - Target the newest macOS APIs. No private API calls. No third-party UI frameworks.
- **Keyboard (first-class, `VISION.md → Core Principles`):** every core action has a shortcut, discoverable in menus; focus behavior predictable and consistent; sidebar ↔ article list ↔ detail pane fully keyboard-navigable; the app is operable without a mouse.
- **Readability:** good contrast at all times; comfortable body-text sizes for long sessions; clear information hierarchy at a glance; premium / calm / harmonious — reduce noise, not information.
- **Accessibility:** VoiceOver labels/hints, Dynamic Type, Reduced Motion respected on every surface.
- **Documented thresholds to exercise at the threshold** (HIG-documented limits are exactly where bugs sit; testing below them is a false pass — the preview matrix must include the threshold case):
  - Alert / `confirmationDialog` button count — truncation past ~10 buttons; use a sheet + picker beyond that.
  - `Picker` style — `.menu` above ~7 options, `.inline` below.
  - Sheet minimum / maximum widths per HIG → Sheets.
  - `NavigationSplitView` sidebar nesting depth per HIG recommendation.
  - Reference shape: PR #118 preview `Recategorize Sheet — Large N` (22 targets).

---

## 12. Best practices source

`architect` and `ux-guardian` fetch Apple's current best practices and Human Interface Guidelines via the `ctx7` tool (see `~/.claude/rules/context7.md`) before every design and review pass, and cite the doc / HIG section in their reports. Topics include: Swift Concurrency, SwiftData `@ModelActor` and schema migration, Observation framework, `NavigationSplitView`, keyboard navigation patterns, accessibility, focus management, Dynamic Type.

Training-data memory is not an acceptable source for API syntax or HIG specifics.

---

## 13. Code conventions (Swift specifics)

Universal conventions (value types, immutability, composition, comments, dead code) live in `CLAUDE.md → Code conventions`. Feeder pins these Swift specifics on top:

### Change discipline

- **DRY:** if logic is similar to existing code, refactor to reuse — never copy-paste.
- **Single-purpose functions:** split when a function grows past one responsibility.
- **Minimal-scoped changes:** change only what the task needs; no unrelated refactors mixed into a fix.
- **Migrate on contact:** when touching code that uses a §7-prohibited pattern, migrate it as part of the change. Do not introduce files with legacy patterns "to be fixed later". Build stays clean after every commit.

### File organization

- **Models (`@Model`):** properties → relationships → classification fields → `init()`.
- **Actors / classes:** static properties (logger) → instance properties → init → methods by purpose.
- **Views:** `@Environment` / `@Binding` → `@State` → `@Query` → `var body` → helper views → `#Preview`.
- **DTOs:** properties only, marked `nonisolated` + `Sendable`.
- Use `// MARK: - Section Name` to separate logical concerns.

### Naming

- All identifiers in English; descriptive, intention-revealing names.
- Booleans in predicate form — `isRead`, `isClassified`, `isTopLevel`.
- Functions with a descriptive verb prefix — `persist`, `fetch`, `apply`, `detect`, `strip`.

### Formatting

Mechanical formatting is enforced by `swift-format` (§2). Beyond it: blank line between methods and between MARK sections; no blank lines between grouped property declarations.

### Access control

- Default: implicit `internal` (no keyword); `private` for implementation details.
- `nonisolated` on helpers and DTOs crossing actor boundaries.

### Error handling

- Shorthand unwrapping preferred: `guard let entry else { return }`.
- `if let` only when the unwrapped value is used in the immediately following block.
- `throws` for data operations that can fail; typed throws when the error domain is known: `func fetchEntries() throws(FeedbinError) -> [EntryDTO]`.

### Collections

- `Dictionary(uniqueKeysWithValues:)`, `Dictionary(grouping:by:)` over manual loops.
- `map` / `filter` / `compactMap` over `for` loops for pure transformations.
- `stride(from:to:by:)` for batching; `lazy` for chained operations to avoid intermediate allocations.

### Mandatory async patterns

```swift
// Periodic work — owned, cancellable:
private var periodicTask: Task<Void, Never>?

func startPeriodicWork(interval: TimeInterval) {
  periodicTask?.cancel()
  periodicTask = Task {
    while !Task.isCancelled {
      await doWork()
      try? await Task.sleep(for: .seconds(interval))
    }
  }
}

// UI-triggered async:
Button("Sync") {
  Task { await syncEngine.sync() }
}
```

---

## 14. Intentional Divergences

A divergence requires a measurement-backed reason, a clear benefit, and an isolated exception. Document it here when you take it.

| Date | Rule | Divergence | Reason |
| ---- | ---- | ---------- | ------ |
| 2026-05-14 | Remote CI (`CLAUDE.md → Verification`) | No GitHub Actions; `make test-all` is the contracted local gate. | Single-developer project, PR template enforces verification. Revisit if contributor count > 1 or verification is skipped in any merged PR. |
| 2026-05-14 | MainActor must not perform synchronous IO (`CLAUDE.md → Responsiveness & resource budget`) | `SyncEngine.lastSyncDate` and `pendingReadIDsToSync` accessors keep synchronous `UserDefaults` reads/writes on MainActor. | Writes occur at human-event frequency (sync completion, mark-read), are `CFPreferences`-cached in-process, and benchmark below 100 µs — well inside the 16 ms / 8.3 ms frame budget. Wrapping in an actor adds Task-hop latency on the very path it would protect and forces `ContentView` mark-read handlers to become async. Revisit if Instruments shows MainActor hang attributable to these accessors, or if call frequency rises (e.g., per-scroll persistence). |
| 2026-05-15 | Evidence over opinion (`VISION.md → Core Principles`) | `ClassificationEngine` heuristics — `applyConfidenceGate` (threshold 0.3), `keywordMatchConfidence` weights (title 0.8 / body 0.4), `keywordOverrideThreshold` (0.8), and language-gating — ship as calibrated values without precision/recall measurement. | MVP has one user (the developer); synthetic 30-fixture evals lack statistical power (95% CI ±10–15%) and risk confirmation bias when written by the same person tuning the gates. `VISION.md → Success Definition` frames classification correctness as human-verifiable, not benchmark-driven. Revisit when: (a) real user base produces a labeled-by-third-party corpus of ≥100 entries per major category, OR (b) production evidence shows user-facing miscategorisation > 10%. |
| 2026-05-19 | Persistence shape — "Never write migrations" (lifted) | Previous rule was: bump `currentSchemaVersion`, let the store auto-reset on mismatch. This was always destructive — folders, categories, classifications, and feeds were wiped on every schema bump even though articles re-sync from Feedbin. Lifted in favour of SwiftData `VersionedSchema` + `SchemaMigrationPlan` (`FeederSchemaV1` + `FeederMigrationPlan`). User data is now durable across schema changes per `VISION.md → Core Principles` (every ingested article keeps its category assignment). | Revisit only if the migration framework itself becomes a maintenance burden disproportionate to the value of preserved user data. |
| 2026-05-26 | Warnings gate (§1 — no new warnings) | `WebKitPreheat` and `ArticleWebView` set the deprecated `WKWebViewConfiguration.processPool` property to share a preheated Web Content Process across article-detail views. | Apple ships no first-party preheat API in the macOS 26 SDK (`developer.apple.com/documentation/webkit/wkwebview`) and `WKWebsiteDataStore` sharing does not give the same explicit pre-warm control — `WKProcessPool` is the only documented primitive that forces multiple `WKWebView` instances to reuse one Web Content Process. The property carries Apple's deprecation marker but no replacement has shipped; current SDKs still honour the assignment without a hard removal. Revisit when Apple ships a first-party preheat API OR when the deprecation hardens to a removal warning that breaks the warnings gate. |
| 2026-07-07 | Time (`CLAUDE.md → Time`, §10) | `DataWriter` persists `formattedDate` and `formattedPublishedTime` — display-formatted local-time strings pre-computed at write time. | Render-time date formatting is banned on the hot path (§0, §4: no Calendar work in `body`); these fields exist precisely to keep that work off the frame. They are display artifacts only — ordering and logic always use the `Date` instant. Staleness after a timezone change is bounded: fields recompute on the next write and in every custom migration stage (§5). Revisit if timezone-change staleness becomes user-visible, or if profiling shows render-time formatting fits the frame budget. |
