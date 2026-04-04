# Next Actions (Execution Queue)

Date: 2026-04-03
Owner: Repository Owner + Agent
Status: Active

## Rules

- Every item includes owner and acceptance criteria.
- Move completed items to the history section with date and evidence link.

## Active queue

1. **Category model redesign: folders + categories** — PR #46 (in review)
   - Owner: Owner + Agent
   - Folder (optional UI grouping) + Category (flat classification label). Single category per article. Drag-and-drop management.

## Completed history

- **2026-04-03**: Sync read status to Feedbin — fire-and-forget push via DELETE /v2/unread_entries.json, push-before-pull in incremental sync, eager push on app background. PR #42.
- **2026-04-03**: Keep days runtime — date-based @Query filtering hides articles outside retention window without deletion, classification cancel/restart on setting change, fixed 30-day startup purge. PR #41.
- **2026-04-03**: Test suite quality review — fixed Keychain prompt (CODE_SIGNING_ALLOWED=NO), split test gates, removed 19 low-value tests, added 13 DataWriter entry integration tests, deleted launch tests. PR #39.
- **2026-04-03**: Codereview skill: added premium quality standard, zero-tolerance policy, and 4 new checks (dead code, duplication, leftover markers, naming & clarity).
- **2026-04-03**: Review and align app-rules.md and swift-code-rules.md — audited both files, rewrote app-rules.md as design principles, moved vision.md to docs/, unified naming.

See merged pull requests on GitHub for full audit trail.

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update this file promptly.
