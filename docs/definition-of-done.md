# Definition of Done — Feeder

A change is not done unless ALL of these hold. The `qa-enforcer` agent walks this list item by item before approving a PR. The PR template references the same list.

Detail on each rule lives in the linked source — this file is a checklist, not a duplicate of the rules.

## Verification

- [ ] `make test-all` passes with zero warnings (`stack.md` → Build & verify commands).
- [ ] Tests cover new domain logic (`swift-code-rules.md` → Core Principles).
- [ ] UI changes have SwiftUI previews exercising every state listed under "UI states" below.

## Architecture & concurrency

- [ ] All writes go through `DataWriter` — no `ModelContext` on MainActor (`swift-code-rules.md` → Two-Layer Architecture).
- [ ] No heavy work on MainActor — no regex/loops/Calendar math in `body` (`app-rules.md` → Performance).
- [ ] Every async path is cancellation-safe (`swift-code-rules.md` → Mandatory Patterns).
- [ ] No prohibited patterns introduced (`swift-code-rules.md` → Strict Prohibitions).
- [ ] DTOs crossing actors are `nonisolated struct` + `Sendable` (`swift-code-rules.md` → Actor Boundaries).

## UI states

For every user-visible surface that the change touches, the following states are rendered and previewed:

- [ ] Loading / awaiting first data
- [ ] Success
- [ ] Empty
- [ ] Error
- [ ] Offline
- [ ] Permission-blocked (when applicable)

## Apple platform conformance

- [ ] Keyboard navigation works for new surfaces (`app-rules.md` → Keyboard Navigation).
- [ ] Native SwiftUI components used — no custom chrome where standard solves the problem (`app-rules.md` → Vanilla macOS).
- [ ] System colors and system fonts used (`app-rules.md` → Vanilla macOS).
- [ ] Apple's current best practices verified via `ctx7` for the APIs touched (`stack.md` → Best practices source).

## Privacy & safety

- [ ] No PII or API keys logged — `.private` interpolation used for user-derived values (`stack.md` → Logging & privacy).
- [ ] Privacy declaration (`PrivacyInfo.xcprivacy`) updated if a new data flow was introduced.
- [ ] No new third-party dependencies without an entry in `stack.md` → Approved dependencies.
- [ ] No `.env` content or secrets in the diff (`CLAUDE.md` → Safeguards).

## Persistence

- [ ] If the schema changed: a new `VersionedSchema` is added, `FeederMigrationPlan.schemas` and `.stages` updated, and a migration stage (lightweight or custom) connects it to the previous version (`stack.md` → Persistence shape).
- [ ] If the change touches inputs to denormalized display fields (`plainText`, `formattedDate`, `formattedPublishedTime`, `primaryCategory`, `primaryFolder`, `displayDomain`, `summaryPlainText`, `articleBlocksData`): the migration stage is `.custom` and recomputes those fields in `willMigrate` / `didMigrate`.

## Code hygiene

- [ ] No `print()`, `TODO`, `FIXME`, `HACK`, or commented-out code in the shipped diff (`swift-code-rules.md` → Strict Prohibitions).
- [ ] No `@unchecked Sendable`, `nonisolated(unsafe)`, or force-unwraps outside tests/previews (`swift-code-rules.md` → Core Principles).
- [ ] Naming is self-documenting (`swift-code-rules.md` → Code Style → Naming).
- [ ] Changes are minimal-scoped — no unrelated refactors mixed in (`swift-code-rules.md` → Code Style).

## Performance

- [ ] Performance budgets respected (`stack.md` → Performance budgets). Profile any change that touches the hot path.
