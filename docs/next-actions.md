# Next Actions (Execution Queue)

Date: 2026-04-04
Owner: Repository Owner + Agent
Status: Active

## Rules

- Every item includes owner and acceptance criteria.
- Move completed items to the history section with date and evidence link.

## Active queue

- **B-minimum refactor queue** (P2–P9 of 9): EditSheetShell; LabelGeneration rename; SyncStatusView calendar-math move; Entry model split; DataWriter domain-split + `fetchCategory(label:)`; SyncEngine role separation + withTaskGroup limiter; typed throws rollout + FeederApp startup async; ContentView decomposition. Picked up one PR at a time.

## Completed history

- **2026-04-19**: B-minimum refactor P1 — PR #58 merged. Removed `nonisolated` shared `DateFormatter` in `Feeder/Helpers/EntryFormatting.swift` (Swift 6 strict-concurrency rule fix); replaced with value-type `Calendar.dateComponents` + `String(format:)` for byte-identical `"HH.mm"` output; extracted `ordinalSuffix(forDay:)` helper. Added `OrdinalSuffixTests` (5) and `EntryTimeFormattingTests` (5) to lock both contracts. Two codereview rounds: round 1 required tests for both new helpers, round 2 PASS with zero findings.
- **2026-04-18**: Article-list scroll preservation + SyncEngine refactor — PR #56. EntryListView split into structural + refresh tasks so sync/classification ticks diff in place instead of tearing down the List; refresh bumps gated on new-entry / classified counts; secondary sort on feedbinEntryID for deterministic ordering. Also collapsed syncUnread / syncIncremental / refetchHistory's inline loop into a single fetchEntriesSince path (−49 lines net).
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
