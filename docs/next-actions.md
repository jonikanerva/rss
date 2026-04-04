# Next Actions (Execution Queue)

Date: 2026-04-04
Owner: Repository Owner + Agent
Status: Active

## Rules

- Every item includes owner and acceptance criteria.
- Move completed items to the history section with date and evidence link.

## Active queue

*(Queue empty)*

## Completed history

- **2026-04-04**: Embedded video/iframe thumbnails — PR #49. YouTube iframes replaced with clickable thumbnail images in both web and reader view. Extensible to other platforms.

- **2026-04-04**: UI/UX tweaks — PR #48. API key edit modal, removed standalone Reclassify button, J/K sidebar navigation, menu bar commands (Sync, Mark All Read, Reader/Web, Open in Browser, Navigate).
- **2026-04-04**: Article content tweaks — PR #47. Web view now shows feed content (content > summary), reader view shows extracted content (extractedContent > content > summary). Empty articles show "Open in browser" fallback. Root cause of "if you trust this content" was Mercury Parser overriding good feed content.
- **2026-04-04**: Category model redesign: folders + categories — PR #46 merged. Folder (optional UI grouping) + Category (flat classification label), single category per article, drag-and-drop management.
- **2026-04-03**: Sync read status to Feedbin — fire-and-forget push via DELETE /v2/unread_entries.json, push-before-pull in incremental sync, eager push on app background. PR #42.
- **2026-04-03**: Keep days runtime — date-based @Query filtering hides articles outside retention window without deletion, classification cancel/restart on setting change, fixed 30-day startup purge. PR #41.
- **2026-04-03**: Test suite quality review — fixed Keychain prompt (CODE_SIGNING_ALLOWED=NO), split test gates, removed 19 low-value tests, added 13 DataWriter entry integration tests, deleted launch tests. PR #39.
- **2026-04-03**: Codereview skill: added premium quality standard, zero-tolerance policy, and 4 new checks (dead code, duplication, leftover markers, naming & clarity).
- **2026-04-03**: Review and align app-rules.md and swift-code-rules.md — audited both files, rewrote app-rules.md as design principles, moved vision.md to docs/, unified naming.

See merged pull requests on GitHub for full audit trail.

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update this file promptly.
