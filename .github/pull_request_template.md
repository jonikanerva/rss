<!-- Keep this proportional to the change. Use short, active English sentences.
Remove instructions and replace placeholders before saving. -->

## Purpose and scope

<Problem, intended outcome, and what this change delivers.>
<Put any decisive unresolved owner decision or product blocker first.>
<Link a fully resolved issue with Closes #N when applicable.>

## Acceptance criteria

<Observable behaviour, important failure cases, and the evidence for each.>
<Trace criteria to the original request or source evidence. Separate material
assumptions from requirements and observed facts; state unresolved user-visible effects.>

## Decisions and authority

<Material choices and the `VISION.md` / `STACK.md` rules at play.>
<A decision that binds future work, also stated in the linked issue.>

VISION decision filter (`VISION.md → Decision Filter`):

1. Exactly one main category per article — **<yes / no>**. <Reason.>
2. Timeline order stays canonical timestamp descending — **<yes / no>**. <Reason.>
3. Calm, keyboard-operable, vanilla macOS — **<yes / no>**. <Reason.>
4. Smallest polished capability, reversible — **<yes / no>**. <Reason.>

The owner merges this PR (`CLAUDE.md → Owner reservations`).

## Verification

- Version and integration base: <head SHA and base SHA>
- `$VERIFY_CMD`: `verify: head=<sha> tree=clean result=Passed tests=<n>`
- Hot-path gate (`STACK.md § 4`): <not triggered / no new hot-path work and why / test and signpost per unit>
- Owner-run checks (`STACK.md § 3 → Gates`): <none triggered / `ran on <SHA>: PASS` / `triggered, pending owner run`>
- Other triggered gates: <`make test-stress-tsan`, schema migration test, or none>
- States handled (user-facing surfaces): <each applicable state and its preview, or not applicable>
- Privacy declaration (`PrivacyInfo.xcprivacy`): <updated, or no new required-reason API>
- Reproduction: <procedure, safe inputs or reconstruction, expected outcomes and sources>
- Independent review: <required or not, reason, and review link when complete>

## Unverified work and exceptions

<Lead with any decisive unresolved risk. State what was not verified and its
effect on acceptance. Unrepeatable claims are limitations, not passed checks.
Use none with a reason when all applicable evidence is present. Link each
approved exception in `STACK.md § 14`.>

## Release and recovery

<Schema migration and compatibility evidence, or not applicable with a reason.
The owner releases with `make install` after the merge (`STACK.md § 16`).>
