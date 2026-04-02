# Research: Makefile DX & GitHub App Auth Removal

**Date:** 2026-04-02
**Status:** Complete — sufficient evidence to plan

## Problem

Two developer experience pain points:

1. **Fragmented build tooling.** Five separate bash scripts in `.claude/scripts/` handle lint, build, unit tests, UI tests, and artifact collection. Running individual phases requires knowing script paths and environment variables. There's no single entry point for common operations like "just lint" or "lint and fix".

2. **Unnecessary GitHub App authentication ceremony.** Every push/PR requires running `bash .claude/scripts/use-github-app-auth.sh`, which mints JWT tokens via a GitHub App installation. This adds friction for both human developers and AI agents. The `Co-Authored-By: Claude` trailer already provides attribution — the App auth adds no value for a single-developer project.

## Constraints

- macOS-only project (no Linux CI) — `make` is available via Xcode Command Line Tools.
- `swift-format` lives inside Xcode toolchain at a fixed path.
- Existing scripts have well-tested xcodebuild invocations with specific code signing flags — these must be preserved exactly.
- `CLAUDE.md` is the single source of truth for agent behavior — all references must be updated atomically.
- Four Claude skills reference scripts: `/research`, `/plan`, `/implement`, `/codereview`.
- Gate enforcer hook (`.claude/hooks/gate-enforcer.sh`) does NOT reference GitHub App auth — no changes needed there.

## Alternatives

### A1: Makefile wrapping existing scripts (Recommended)

Create a `Makefile` at repo root that delegates to existing bash scripts but adds convenience targets.

**Targets:**
| Target | Action |
|--------|--------|
| `make lint` | swift-format lint (check only) |
| `make lint-fix` | swift-format format (auto-fix) |
| `make build` | build-for-testing.sh |
| `make test` | Unit tests only |
| `make test-ui` | UI smoke tests only |
| `make test-all` | Full gate: lint + build + unit + UI (= test-all.sh) |
| `make clean` | Remove derived data + xcresult artifacts |

**Pros:**
- `make` is universally available on macOS, zero dependencies.
- Tab-completion for targets out of the box.
- Agents can call `make lint-fix` instead of finding the swift-format binary path.
- Existing scripts continue to work for anyone who prefers them.
- Declarative dependency graph (e.g., `test` depends on `build`).

**Cons:**
- Makefile syntax can be surprising (tabs, not spaces).
- One more file in repo root.

### A2: Makefile replacing scripts entirely

Move all logic from bash scripts into Makefile targets directly.

**Pros:** Single file, no indirection.
**Cons:** Harder to maintain complex xcodebuild invocations in Makefile syntax. Loses the `set -euo pipefail` safety net of bash. The existing scripts are well-tested — rewriting is risk without reward.

### A3: Swift Package Manager plugin / Tuist

Use SPM plugins or Tuist for build orchestration.

**Pros:** Swift-native tooling.
**Cons:** Massive scope change. Project uses native Xcode project, not SPM. Would require project restructuring. Overkill for the problem.

### GitHub App Auth Removal

**Option: Delete script, remove all references.** The user's standard git credentials (SSH key or personal token) handle push/PR. `Co-Authored-By: Claude` trailer provides attribution.

Only 3 files reference the auth script:
1. `.claude/scripts/use-github-app-auth.sh` — delete
2. `CLAUDE.md` line 125 — remove instruction
3. `.claude/skills/codereview/SKILL.md` line 13 — remove prerequisite

No hooks, settings, or other scripts reference it.

## Evidence

**Current script inventory and their roles:**

| Script | Lines | Purpose | Makefile target |
|--------|-------|---------|-----------------|
| `test-all.sh` | 112 | Full test gate (lint+build+unit+UI) | `make test-all` |
| `build-for-testing.sh` | 32 | xcodebuild build-for-testing | `make build` |
| `ui-smoke.sh` | 43 | UI smoke test runner | `make test-ui` |
| `collect-test-artifacts.sh` | ~30 | xcresulttool JSON extraction | `make artifacts` (optional) |
| `use-github-app-auth.sh` | 114 | GitHub App JWT auth | **DELETE** |

**swift-format binary location:** `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format`

**Makefile prior art in Swift projects:** Common pattern. Apple's own swift-format repo uses a Makefile. Many open-source Swift projects (Vapor, swift-nio) use Makefiles for convenience targets.

## Unknowns

1. **Will removing GitHub App auth break any Conductor-level workflow?** — Low risk. The auth script is project-level, not Conductor infrastructure. The user explicitly requested removal.

**Biggest risk:** Forgetting to update a reference to the auth script, causing agent failures on push/PR. Mitigated by comprehensive grep search (already done — only 3 files).

## Recommendation

Evidence is sufficient to plan. Recommended approach:

1. **Create `Makefile`** at repo root wrapping existing scripts (A1).
2. **Delete** `.claude/scripts/use-github-app-auth.sh`.
3. **Update** `CLAUDE.md` — replace auth instruction, update Build Verification section to reference `make` commands.
4. **Update** `.claude/skills/codereview/SKILL.md` — remove auth prerequisite.
5. **Update** `.claude/skills/implement/SKILL.md` — reference `make` commands instead of raw script paths.
6. **Update** `CLAUDE.md` Mandatory Test Gate to reference `make test-all`.
7. **Keep** existing bash scripts — they remain the implementation, Makefile just delegates.
