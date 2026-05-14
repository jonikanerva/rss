# Stack — Feeder

Concrete technology stack, build/verify commands, performance budgets, and persistence shape. The single source of truth for technology choices. All agents and CLAUDE.md reference this file by name and section.

Swift-language rules and forbidden patterns live in `swift-code-rules.md`. Design principles live in `app-rules.md`. Product vision lives in `vision.md`. This file does not duplicate any of them.

---

## 1. Language & runtime

- **Primary language:** Swift 6.1
- **Strictness:** `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. No new warnings; no `@preconcurrency` ratchet-loosening.
- **Target runtime:** macOS 26+
- **Minimum runtime version:** macOS 26.0 (no back-deployment, no `#available` for older OSes)
- **Package manager:** Swift Package Manager (`Package.resolved`)
- **Build tool:** Xcode 26+, Swift 6 language mode

---

## 2. Frameworks

| Concern | Framework / library | Notes |
| ------- | ------------------- | ----- |
| UI / view layer | SwiftUI | AppKit only as a wrapped adapter |
| State / observation | Observation (`@Observable`, `@State`, `@Bindable`, `@Environment`) | No `ObservableObject` / `@StateObject` / `@ObservedObject` / `@EnvironmentObject` for new code |
| Concurrency | async / await, `AsyncSequence`, actors, structured concurrency | See `swift-code-rules.md` for the full prohibition list |
| Navigation | `NavigationSplitView`, `NavigationStack` | No `NavigationView` |
| Networking | `URLSession` async / await | |
| Persistence | SwiftData (`@Model`, `ModelContainer`, `@Query`) via `DataWriter` (`@ModelActor`) | See §5 |
| Feedbin sync | Custom `FeedbinClient` (`actor`) | |
| Classification | Apple Foundation Models (on-device, primary); OpenAI API (optional, user-supplied key) | |
| Logging | `os.Logger` per subsystem / category | No `print()` in shipped code (see `swift-code-rules.md`) |
| Telemetry | None | No third-party analytics |
| Testing | Swift Testing (`@Test`, `@Suite`, `#expect`); XCTest / XCUITest for end-to-end UI | |
| Formatting | `swift-format` with repo `.swift-format` | No SwiftLint |

---

## 3. Build & verify commands

| Variable | Command |
| -------- | ------- |
| `$FORMAT_CMD` | `make lint-fix` |
| `$LINT_CMD` | `make lint` |
| `$BUILD_CMD` | `make build` |
| `$TEST_CMD` | `make test` |
| `$VERIFY_CMD` | `make test-all` (lint → build → unit tests) |
| `$TEST_FULL_CMD` | `make test-full` (lint → build → unit + UI tests) |

The `Makefile` at the repository root is the single source of truth for these commands. Never invoke `swift-format`, `xcodebuild`, or `xcrun` directly from commits, CI, or agent scripts — always go through `make`.

---

## 4. Performance budgets

- **UI frame budget:** 16 ms baseline; 8.3 ms on ProMotion displays.
- **Cold start:** < 2 s on supported Macs.
- **Memory ceiling:** < 500 MB resident during normal browsing.
- **Article list scroll:** 120 fps achievable on ProMotion.
- **Sync background work:** must not block UI; long-running classification batches are cancellable and yield cooperatively.

Profile before optimizing. Stay inside these budgets unless a measurement-backed Intentional Divergence (§10) is recorded.

---

## 5. Persistence shape

- **Storage primitive:** SwiftData (`@Model`, `ModelContainer`, `@Query`).
- **Writes:** ALL writes go through `DataWriter` (`@ModelActor`). No `ModelContext` on MainActor. See `swift-code-rules.md` → Two-Layer Architecture.
- **Schema versioning:** bump `currentSchemaVersion` in `FeederApp.swift` when the schema changes. Database auto-resets on version mismatch. Never write migrations.
- **Pre-computed display fields:** `DataWriter` pre-computes `plainText`, `formattedDate`, `primaryCategory` at write time.

---

## 6. Approved dependencies

| Dependency | Purpose | Approver | Date |
| ---------- | ------- | -------- | ---- |
| *(Apple frameworks only by default)* | — | — | — |

Adding a new third-party SPM dependency requires an entry in this table before it lands in `Package.resolved`.

---

## 7. Stack-specific reject-list additions

These supplement (do not replace) the prohibitions in `swift-code-rules.md` → Strict Prohibitions. Read both before approving a change.

- `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, `@Published` in new code — Observation framework only.
- `NavigationView` — `NavigationSplitView` / `NavigationStack` only.
- `ModelContext` on MainActor for writes — all writes through `DataWriter`.
- Filtering `@Query` results in Swift — push predicates to SQLite via the `@Query` predicate.
- Adding a new SwiftPM dependency without a §6 entry.

---

## 8. Logging & privacy

- **Logger:** `os.Logger` per subsystem / category. Patterns in `swift-code-rules.md` → Mandatory Patterns → Logging.
- **PII redaction:** use `os.Logger` `.private` interpolation for any value derived from user data (article URLs, feed URLs, API keys, classification prompts).
- **Crash reporter:** none. No Sentry / Crashlytics / equivalent.
- **Privacy declaration:** keep `PrivacyInfo.xcprivacy` accurate. Every required-reason API call is declared.
- **Secrets:** never live in the repo. Configuration via `.env` (gitignored) or Keychain.

---

## 9. Best practices source

Both `architect` and `ux-guardian` agents fetch Apple's current best practices and Human Interface Guidelines via the `ctx7` tool (see `~/.claude/rules/context7.md`) before every design and review pass. Topics include: Swift Concurrency, SwiftData `@ModelActor`, Observation framework, `NavigationSplitView`, keyboard navigation patterns, accessibility, focus management, Dynamic Type.

Agents do not rely on training-data memory for API syntax or HIG specifics — they query `ctx7` and cite the doc / HIG section in their report.

---

## 10. Intentional Divergences

| Date | Rule | Divergence | Reason |
| ---- | ---- | ---------- | ------ |
| 2026-05-14 | Same-story grouping UI | Deferred from MVP; data layer ready (`storyKey` computed and persisted on `Entry`), UI surfacing post-MVP. | Reduces MVP surface; classification correctness verified before UI investment. |
| 2026-05-14 | Remote CI | No GitHub Actions; `make test-all` is the contracted local gate. | Single-developer project, PR template enforces verification. Revisit if contributor count > 1 or verification is skipped in any merged PR. |

A divergence requires a measurement-backed reason, a clear benefit, and an isolated exception. Document it here when you take it.
