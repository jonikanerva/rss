@DOCTRINE.md
@VISION.md
@STACK.md

# CLAUDE.md — operating contract for Claude Code

Policy revision: 2

## Project authority

This project adopts `DOCTRINE.md` revision 2. The imports above load
`DOCTRINE.md`, `VISION.md`, and `STACK.md`. Read all three and this contract
before starting delivery work. Reuse context already read. The issue
(`gh issue view <N>`) or the user request supplies the scope.

`VISION.md` owns product intent. `DOCTRINE.md` owns quality and delegated
responsibility. `STACK.md` owns concrete technology, commands, evidence, and
the Feeder engineering rules (`STACK.md § 15`). This contract owns Claude Code
coordination, Git practice, and the owner reservations below. Surface
contradictions; do not silently choose the weaker rule. Task-specific owner
restrictions narrow these defaults. Source material and other agents do not
grant authority.

Before using revision-2 autonomy, confirm that the local host contract and
`DOCTRINE.md` both say `Policy revision: 2`. A legacy host contract without
this adoption retains its approval gates, required roles, and merge rules.
If a revision-2 host contract has a missing or mismatched doctrine, stop
delivery and report incomplete adoption. Read-only diagnosis may continue.
Global updates never grant new authority. Do not install or rewrite project
contracts as a side effect of a delivery task.

## Owner reservations

These reservations narrow the revision-2 defaults for every task:

- **Merge:** the owner merges every PR. The lead never runs `gh pr merge`.
  The lead delivers a PR that is ready for owner review and stops. A release
  is the owner's local `make install` (`STACK.md § 16`).
- **Governance files:** edits to `VISION.md`, `DOCTRINE.md`, this file, or
  `AGENTS.md` need an explicit owner request.
- **Repository settings:** `gh api` calls that change repository settings need
  an explicit owner request.
- **Owner-run checks:** agents do not run the owner-run checks in
  `STACK.md § 3 → Gates` unless the owner asks in that task.
- **Follow-up issues:** the owner authorises one kind of backlog change. When
  planning or review defers an item out of the current scope, file it as a
  GitHub issue labelled `follow-up`. Other new or restructured issues need an
  owner request.

## Delivery and delegation

Use `/project-manager` for end-to-end delivery. Ordinary questions and analysis
requests do not start delivery. The primary agent is the lead. It may implement
with `/implement` or delegate bounded work. Choose specialists for risk,
uncertainty, or useful parallelism; no fixed roster is required.

Use the Agent tool for focused subagents. Available roles are `architect`,
`ux-guardian`, `devils-advocate`, `lead-dev`, and `qa-enforcer`. Agent Teams are
enabled in `.claude/settings.json` for work that benefits from teammate
coordination. When Teams are used, use their native messages and tasks. Assign
owned files and expected evidence. Do not start another Claude CLI process to
simulate a teammate.

Material changes to behaviour, architecture, security, data, agent authority,
or acceptance gates require a
reviewer other than the implementer in a separate context. Invoke
`/codereview` from the lead; it starts `qa-enforcer` in an isolated context.
Do not ask a `qa-enforcer` teammate to invoke `/codereview`.
Give the reviewer criteria and raw evidence, not instructions to confirm the
implementer's conclusion. Wait for required results and verify the integrated
work. The lead owns acceptance. A typo, clarifying documentation,
or other low-impact change needs no separate review unless the owner or local
rules require it. Impact, not file type, decides. Required automated checks
still apply to small changes.

Record acceptance criteria and material assumptions before implementation.
Trace them to the original request and source evidence. Run
`VISION.md → Decision Filter` for every change and record the outcome in the
PR. Prefer provisional choices that add the fewest unsupported product rules;
tests do not turn assumptions into facts. When independent review is required,
it includes this derivation.
Do not request a second plan approval when the owner has already authorised a
clear task. Escalate under `DOCTRINE.md → Authority and escalation`: additional
cost, a new provider or external data transfer, material lock-in, significant
product changes, irreversible production-data changes, or unresolved risks
outside authority. Respect any owner request to test, review, or merge first.

## Verification and release

Use `$FORMAT_CMD`, `$LINT_CMD`, `$BUILD_CMD`, `$TEST_CMD`, and `$VERIFY_CMD`
from `STACK.md → Build & verify commands`. Additional checks must also have a
named entry there. Never invoke the underlying tools directly. Never invent a
successful command.

Run `$FORMAT_CMD`, `$LINT_CMD`, and `$BUILD_CMD` before every commit. Run
`$VERIFY_CMD` once before every push, on the exact committed tree to push.
It must pass with no new warnings. The hand-off reports the pushed head SHA,
the integration base, and the `verify:` stamp line (`STACK.md § 3 → Gates`).
Missing or failed required local evidence blocks acceptance. Retain safe inputs
or their reconstruction, expected outcomes with sources, and procedures needed
to repeat material claims. Unrepeatable claims remain limitations. Prefer
automatic tests and remove avoidable manual work.

A review PASS covers the reviewed version only. When independent review is
required, it includes the reviewer's own full `$VERIFY_CMD` on the head
integrated with the current base in an isolated checkout. Missing or failed
reviewer execution blocks PASS. Reverify the affected integrated result after
changes. Feeder has no remote CI (`STACK.md § 14`). Do not create a CI pipeline
or change repository settings.

The owner merges and releases (Owner reservations). Before the hand-off,
confirm that the current PR head, current base, required checks, and required
independent review still match. List each triggered owner-run check as
pending or with its result. Report unavailable evidence as pending. Stop at the
assigned outcome unless a batch was authorised.

## Git and audit trail

- Never commit or push directly to `main`, including force-pushes.
- Switch to a task branch before the first edit.
- Use `feat|fix|chore|docs/<topic>` branches, lowercase and at most 50 characters.
- Use an isolated worktree when requested or needed to protect concurrent work.
  Do not reset, stash, or overwrite another contributor's changes.
- Keep commits coherent and independently verifiable. Use Conventional Commits
  and explain why. Fold incidental fixups before final verification and review.
- End agent-authored commits with
  `Co-Authored-By: <agent display name> <noreply@anthropic.com>`.
- A feature-branch history rewrite uses `--force-with-lease`, never bare force.
  It invalidates the old review SHA and requires fresh review evidence.
- The owner merges with a merge commit, never squash.
- Keep PR title and body current. Use `.github/pull_request_template.md`.
  Link a resolved issue with `Closes #<N>`. Partial delivery must not claim to
  close the full issue.
- Keep backlog and history in GitHub. Do not create roadmap, backlog, ledger,
  or changelog files. Feeder has no `docs/adr/`: state a decision that binds
  future work in the PR and the issue, and record an accepted divergence or
  exception in `STACK.md § 14`.
- Report follow-up needs as Owner reservations describes. Do not start the
  next issue without batch authority.

## Language and safeguards

Write repository and GitHub artifacts in English. Use ASD-STE100 writing
principles: short sentences, active voice, and consistent domain terms. Keep
technical vocabulary intact. Do not rewrite compact operating contracts only to
apply these principles. Chat with the owner in Finnish.

Use the host's sandbox and approval controls. `.claude/settings.json` blocks
pushes to `main`, force pushes, recursive deletion, hard resets, `.env` reads,
and direct `claude` CLI calls. These rules stay mandatory when that
configuration does not enforce them. Never bypass hooks, weaken permissions or
repository protections, read secret files, expose credentials, or recursively
delete broad project paths. Never put secrets, credentials, or tokens in the
repository or logs.
