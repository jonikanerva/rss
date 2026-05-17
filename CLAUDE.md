# Feeder — Project Rules

A macOS RSS reader: SwiftUI + SwiftData, Feedbin sync, on-device classification via Apple Foundation Models or OpenAI. Native Xcode project: `Feeder.xcodeproj`.

Product vision: `docs/vision.md`. Concrete stack and verify commands: `docs/stack.md`.

## Language Policy

- All project artifacts in **English**: code, comments, commits, branch names, PR titles, variable names.
- User communication in **Finnish**.

## Where the rules live

CLAUDE.md is a short index. Project rules live in `docs/`:

| File | Owns |
| --- | --- |
| `docs/vision.md` | Product vision, non-negotiable outcomes (human-owned) |
| `docs/stack.md` | Tech stack, `$VERIFY_CMD` and friends, performance budgets, approved dependencies, persistence shape |
| `docs/swift-code-rules.md` | Swift 6 rules, two-layer architecture, actor boundaries, strict prohibitions, code style |
| `docs/app-rules.md` | Four design principles: performance, keyboard navigation, vanilla macOS, readability |
| `docs/definition-of-done.md` | Checklist a change must satisfy before it can ship |
| `docs/autonomy.md` | How agents proceed under ambiguity; failure mode for repeated verify failures |

Do not duplicate content from these files in CLAUDE.md, agent prompts, or skill prompts — reference them by name and section.

## Verification

Run `make test-all` (`$VERIFY_CMD` in `docs/stack.md`) before every commit and PR — lint, build, unit tests must pass with zero warnings. Full readiness check: `docs/definition-of-done.md`.

## Workflow

- Run `/project-manager <task description>` to drive non-trivial changes end-to-end. The skill turns this Claude Code session into the agent-team **lead** and orchestrates `architect`, `ux-guardian`, `devils-advocate`, `lead-dev`, and `qa-enforcer` as teammates — they discuss directly via the agent-teams channel before and after implementation.
- `/implement` and `/codereview` are skills the team uses internally — `lead-dev` runs `/implement`, `qa-enforcer` runs `/codereview`.
- Agent-teams require the experimental flag (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.json`) and Claude Code v2.1.32 or later.
- Use Claude Code's `/plan` mode for upfront design questions.
- **Follow-ups and deferred work** live as GitHub Issues with the `follow-up` label. Surface them via `gh issue list --label follow-up`. When planning or review discussions defer an item out of the current PR's scope, file a `follow-up` issue rather than leaving the decision in a PR comment or in-conversation note.

## Git Workflow

- Every feature gets its own branch from `main` and PRs back to `main`. NEVER commit or push directly to `main`.
- Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>`.
- Conventional Commits: `<type>(<scope>): <summary>`.
- Commits must be complete logical units — one logical change per commit.
- PRs are merged with merge commit, not squash. Delete the branch after merge.
- **PR as audit trail:** the PR description must fully describe what and why. The `.github/pull_request_template.md` enforces the structure.
- After merge: delete the local and remote feature branch, switch back to `main`, pull.

## Safeguards

- **NEVER** read `.env` files (`.env`, `.env.*`, `.env.local`).
- **NEVER** commit secrets, credentials, API keys, or tokens.
- **NEVER** run `rm -rf` on project directories.
- **NEVER** merge a PR without all verification passing.

## Decision Rights

- **Auto-allow:** read-only commands, local builds/tests, feature branch ops, PR creation.
- **Ask first:** writes outside feature branch, edits to `docs/vision.md` / `docs/stack.md` / `CLAUDE.md`, secrets/auth/billing.
- **Never:** force push, `rm -rf`, push to main, bypass hooks, weaken concurrency settings.
- **Ambiguity:** apply `docs/autonomy.md`.
