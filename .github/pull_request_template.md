<!--
Fill every section. The `/project-manager` skill drafts this for you.
Trivial PRs (typo fixes, dep bumps, dead-code removal) may use "N/A — trivial change" in any section.
-->

## Why

`<One paragraph: the motivation. What problem is this solving and which `docs/` rule is at play?>`

## What

- `<change 1>`
- `<change 2>`
- `<change 3>`

## Vision check

Answers against `docs/vision.md` → Non-negotiable product outcomes:

1. Does every ingested article still get a main category assignment? **`<yes / no>`** — `<one-line rationale>`.
2. Is timeline order still canonical timestamp descending? **`<yes / no>`** — `<one-line rationale>`.
3. Does AI processing leave timeline position unchanged? **`<yes / no>`** — `<one-line rationale>`.

If any answer is `no`, document the conflict and propose the smallest framework-native alternative.

## Rules involved

- `docs/<file>.md` § `<section>` — `<one-line on how this PR honours the rule>`

## Verification

- [ ] `make test-all` (`$VERIFY_CMD` in `docs/stack.md`) ran green.
- [ ] `make lint-fix` is idempotent (re-running produces no diff).
- [ ] Tests added or updated for new logic.
- [ ] `FeederMigrationPlan` updated (new `VersionedSchema` + stage) if the schema changed (`docs/stack.md` → Persistence shape).
- [ ] Walked through `docs/definition-of-done.md` — every applicable box checked.

## States handled

For UI-affecting changes, list every state the new surface renders:

- [ ] Loading / awaiting first data
- [ ] Success
- [ ] Empty
- [ ] Error
- [ ] Offline
- [ ] Permission-blocked (if applicable)

## Decisions made

`<Any ambiguous decision resolved via `docs/autonomy.md` — list alternatives considered and the rationale. Omit if no fallback was used.>`

## Notes for reviewer

`<Anything the reviewer should know that the diff alone does not surface — deferred decisions, open risks, follow-up work.>`

---

**Next step:** the `qa-enforcer` agent runs `/codereview` on this branch before merge.
