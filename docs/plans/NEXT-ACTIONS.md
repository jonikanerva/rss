# Next Actions (Execution Queue)

Date: 2026-04-02
Owner: Repository Owner + Agent
Status: Active

## Rules

- Every item includes owner and acceptance criteria.
- Move completed items to the history section with date and evidence link.

## Active queue

1. **UI performance: scroll jank during sync**
   - Owner: Agent
   - 2nd panel scrolling stutters badly when fetch/classification is running.
   - App rule: UI responsiveness is the top priority, never compromise it.

2. **UI polish: colors, selection, animations, metadata display**
   - Owner: Agent
   - Fix dark theme: pure black background is wrong; red highlight too bright.
   - Fix selection styling: inconsistent blue/gray appearance — make it clean and consistent.
   - Add subtle, fast animations for a premium feel.
   - 3rd panel: show favicon + site metadata below article title. Layout: icon left, two rows right (domain in lowercase, byline/author in Title Case). Date in Title Case. No ALL CAPS anywhere.
   - 2nd panel: site name in Title Case.

3. **Review and align app-rules.md and swift-code-rules.md**
   - Owner: Owner + Agent
   - Audit content of both files. Discuss together whether the split is logical and content is current.

4. **Test suite quality review**
   - Owner: Agent
   - UI automation test takes over the entire screen — touching anything fails the test.
   - Keychain password prompt appears every run despite "Always Allow" — must be eliminated.
   - Review whether the tests cover meaningful scenarios or just create friction.

5. **Keep/fetch days: respect setting changes at runtime**
   - Owner: Agent
   - Changing the retention window should cancel in-progress classification for articles that fall outside the new range.
   - Decide article retention strategy: keep already-fetched/classified articles in the database but hide them from UI, so toggling the window back doesn't re-fetch and re-classify.

6. **Category model redesign: folders + categories**
   - Owner: Owner + Agent
   - Replace hierarchical categories with a Folder → Category model. Folders (e.g. "Gaming", "Technology") group categories in the sidebar and show all their articles. Categories (e.g. "PlayStation 5", "Marathon") are the classification labels.
   - Specific categories should not appear in their folder's generic feed — they are "narrower" and exist separately.
   - Category management UI still needs a way to define the folder→category hierarchy, even if the main timeline UI only shows folders.
   - Needs research and design discussion before implementation.

7. **Sync read status back to Feedbin**
   - Owner: Agent
   - When an article is marked as read in the app, sync that status to Feedbin via the API.
   - Ensures read state stays consistent between Feeder and Feedbin (and any other Feedbin clients).

8. **Codereview skill: enforce dead code and duplication checks**
   - Owner: Agent
   - Update `/codereview` to flag dead code, duplication, and leftover TODOs/placeholders.
   - Policy: no "do later" debt — fix everything before merge.

## Completed history

See merged pull requests on GitHub for full audit trail.

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update this file promptly.
