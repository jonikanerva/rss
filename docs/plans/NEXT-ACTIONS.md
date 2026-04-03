# Next Actions (Execution Queue)

Date: 2026-04-02
Owner: Repository Owner + Agent
Status: Active

## Rules

- Every item includes owner and acceptance criteria.
- Move completed items to the history section with date and evidence link.

## Active queue

1. **Review and align app-rules.md and swift-code-rules.md**
   - Owner: Owner + Agent
   - Audit content of both files. Discuss together whether the split is logical and content is current.

2. **Test suite quality review**
   - Owner: Agent
   - UI automation test takes over the entire screen — touching anything fails the test.
   - Keychain password prompt appears every run despite "Always Allow" — must be eliminated.
   - Review whether the tests cover meaningful scenarios or just create friction.

3. **Keep/fetch days: respect setting changes at runtime**
   - Owner: Agent
   - Changing the retention window should cancel in-progress classification for articles that fall outside the new range.
   - Decide article retention strategy: keep already-fetched/classified articles in the database but hide them from UI, so toggling the window back doesn't re-fetch and re-classify.

4. **Category model redesign: folders + categories**
   - Owner: Owner + Agent
   - Replace hierarchical categories with a Folder → Category model. Folders (e.g. "Gaming", "Technology") group categories in the sidebar and show all their articles. Categories (e.g. "PlayStation 5", "Marathon") are the classification labels.
   - Specific categories should not appear in their folder's generic feed — they are "narrower" and exist separately.
   - Category management UI still needs a way to define the folder→category hierarchy, even if the main timeline UI only shows folders.
   - Needs research and design discussion before implementation.

5. **Sync read status to Feedbin**
   - Owner: Agent
   - Implement read state sync back to Feedbin API.

6. **Codereview skill: enforce dead code and duplication checks**
   - Owner: Agent
   - Update `/codereview` to flag dead code, duplication, and leftover TODOs/placeholders.
   - Policy: no "do later" debt — fix everything before merge.

## Completed history

See merged pull requests on GitHub for full audit trail.

## Update cadence

- Update this file at every meaningful handoff and before claiming task completion.
- If active queue changes, update this file promptly.
