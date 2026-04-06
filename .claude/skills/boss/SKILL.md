---
name: boss
description: >
  Quality gate orchestrator. Verifies branch/PR exist, runs dual code review
  (/codereview + /codex:review), fixes issues in a loop, and presents the PR
  for manual testing only when all gates pass.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Skill, Agent
---

# Boss — Quality Gate Orchestrator

Full quality-gate workflow that ensures code is review-clean before human
manual testing. Communicate in Finnish with the user. All code artifacts
(commits, comments, branch names) in English.

## Step 0: Prerequisites

Check all three. If ANY fails, stop immediately and tell the user what is missing.

1. **Branch check:**
   ```
   git branch --show-current
   ```
   Must NOT be `main`. If on main:
   "Olet main-branchilla. Aja ensin `/implement <tehtävä>` luodaksesi feature-branchin ja PR:n."

2. **PR check:**
   ```
   gh pr list --head <branch> --json number,url --jq '.[0]'
   ```
   Must return a PR. If none:
   "PR:ää ei löydy tälle branchille. Aja `/implement` tai luo PR manuaalisesti."

   Store the PR number and URL for later use.

3. **Build check:**
   ```
   make test-all
   ```
   Must pass. If fails:
   "make test-all epäonnistui. Korjaa ongelmat ensin ennen review-kierrosta."

All three passed → proceed to the review loop.

## Review Loop (Steps 1–4)

Track iteration count. Maximum **3 iterations**.

### Step 1: Run /codereview

Invoke the codereview skill:
```
Skill("codereview")
```

After it completes, verify the review state via GitHub API:
```
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --jq '.[-1].state'
```

Record: `codereview_passed = (state == "APPROVED")`

### Step 2: Run /codex:review

Invoke the codex:review skill:
```
Skill("codex:review")
```

Parse the output for the verdict. Record: `codex_passed = (verdict is PASS/approve)`

### Step 3: Evaluate results

**Both passed** → skip to Step 5 (Final Gate).

**Iteration count >= 3 and not both passed** → STOP. Tell user:
"Kolme korjauskierrosta tehty, mutta review ei vielä mene läpi.
Tarkista löydetyt ongelmat manuaalisesti."
List all remaining findings. Provide PR URL. Stop execution.

**Otherwise** → proceed to Step 4.

### Step 4: Fix issues

1. **Collect** ALL findings from both reviews that reported issues.
   Read each finding carefully — understand the file, line, and nature of the problem.

2. **Fix** each issue following project standards (CLAUDE.md):
   - Swift 6 strict concurrency, zero warnings
   - Two-layer architecture (DataWriter for writes, @Query for reads)
   - Pure functions, value types, proper actor isolation
   - DRY: reuse existing code
   - Descriptive English names

3. **Verify** fixes compile and tests pass:
   ```
   make test-all
   ```
   If fails, fix compilation/test errors (max 5 attempts, same as /implement).

4. **Stage** only changed files — NEVER use `git add -A` or `git add .`

5. **Commit** with conventional commit message:
   ```
   fix(review): <concise description of what was fixed>
   ```

6. **Push:**
   ```
   git push origin <branch>
   ```

7. **PR comment** documenting fixes:
   ```
   gh pr comment <pr_number> --body "<summary of what was fixed and why>"
   ```

8. **Return to Step 1** (next iteration).

## Step 5: Final Gate

All three conditions must be true:
- `/codereview` posted PASS (PR state is APPROVED)
- `/codex:review` returned PASS/approve verdict
- `make test-all` passes (run one final time to confirm)

If the final `make test-all` fails, fix and loop back through Step 4.

## Step 6: Report to User

Tell the user in Finnish:
- Both reviews passed (mention how many iterations it took)
- All tests pass
- PR URL
- End with: **"PR on valmis manuaaliseen testaukseen: <URL>"**

## Rules

- **NEVER** force push
- **NEVER** push to main
- **NEVER** merge the PR — that is for the human after manual testing
- **NEVER** commit secrets or credentials
- **NEVER** skip `make test-all` between fix rounds
- Maximum **3** review-fix iterations
- Each fix round gets its own commit (never amend)
- All findings from BOTH reviewers must be addressed, not just one
- If only one reviewer failed, still re-run BOTH in the next iteration
