1. **Blockers**:
   - For each `#N` under the body's `## Blocked by` heading, check `gh api repos/{owner}/{repo}/issues/N --jq .state`.
   - If any is still open: add the `blocked` label to this issue and end your turn.

2. **Audit against `{{BASE_BRANCH}}`** (is it already done?):
   - Audit `origin/{{BASE_BRANCH}}` (the loop fetched it). If
     `git rev-list --count origin/{{BASE_BRANCH}}..HEAD` is 0, the worktree **is**
     `{{BASE_BRANCH}}`: grep and run tests there. Otherwise read it without switching:
     `git grep <pattern> origin/{{BASE_BRANCH}}`, `git show origin/{{BASE_BRANCH}}:<path>`. For
     each acceptance criterion in the body, look for evidence: grep for the route / table /
     component / file it names, and find the test that covers it. Run only those test files if you
     need proof (not the whole suite).
   - If the criteria name more than ~3 things to locate, delegate the search to one
     `{{INVESTIGATOR_AGENT}}` Agent (pass it the criteria list, ask for a `file:line` table per
     criterion, code and covering test). Its answer replaces your own greps and file dumps.
     Afterwards, read only the files you will actually change.
   - A code criterion is **met** only if the code exists *and* a test covers it. A doc criterion
     (ADR, README, explainer) is met if the file has that content.
   - Write the verdict to the progress file, one line per criterion: `met: <file:line / test>` or
     `missing: <what's lacking>`.
   - **All met** → check every box (step 9), close the issue (comment
     "Already on {{BASE_BRANCH}}: <evidence per criterion>", then PATCH `state=closed`),
     unblock dependents (step 11), set `step: done`. Finished — no branch, no PR.
   - **Some met** → check those boxes now (step 9). The rest of the run covers only the
     `missing` criteria.
   - Real-device and browser checks are yours to do (see "Human-only work → split out"). A
     criterion that needs hosted config, secrets or product sign-off → apply that rule.
   - **Only struck items remain** (all other criteria met, rest already split out) → close the
     issue (comment "Done; human-only items moved to #M", then PATCH `state=closed`),
     unblock dependents (step 11), set `step: done`. No branch, no PR.

3. **Branch Setup**:
   - Done by the loop. Confirm `git branch --show-current` prints
     `{{BRANCH_PREFIX}}<ISSUE_NUMBER>`; if not, go to "If blocked". Don't create or switch branches.

4. **Planning Phase**:
   - **Skip this step** if the missing criteria touch at most 2 files and need no new migration,
     route or shared schema. Note `plan: skipped (small)` in the progress file and go to step 5.
   - Planning skill: `{{PLAN_SKILL}}`. If it is not `none`, don't load it into your own context
     (it would ride along on every later turn). Spawn one `general-purpose` Agent with this
     prompt: *"Run the `/{{PLAN_SKILL}}` skill for Issue #<ISSUE_NUMBER>, scoped to these missing
     criteria: <list>. Conventions already known: <what you learned in step 2>. Write the plan to
     `logs/issue-<ISSUE_NUMBER>.plan.md` (max ~40 lines: each file to create/touch, what changes
     in it, which tests cover it). Reply only `done`."* Then read that plan file and follow it.
   - If it is `none`, write that plan file yourself (same ~40-line shape), then follow it.

5. **TDD Phase**:
   - TDD skill: `{{TDD_SKILL}}`. If it is not `none`, run `/{{TDD_SKILL}}`; otherwise work
     red → green → refactor yourself: write failing tests covering the missing criteria, then
     write the code until they pass.
   - While coding, run the single test file you're working on (not the whole suite) — step 6
     runs the checks once. Use a quiet reporter and cap the output (`… 2>&1 | tail -30`). Only if
     that shows a failure you can't read, re-run that one file verbosely (`| tail -80`). Don't
     run the full typecheck after each edit; step 6 runs it once.
   - Work in batches: read all the files you need in one go, write the related test and code
     files together, then run the tests — not one file per turn.

6. **Local Checks**:
   - From the worktree root run `"{{RALPH}}" checks` and fix everything until green. CI runs the
     full suite before the merge, so don't run more than the checks ask for.

7. **PR Creation**:
   - Commit changes, push the branch to GitHub, and open a Pull Request targeting `{{BASE_BRANCH}}`.
   - Set the PR body to include `Closes #<ISSUE_NUMBER>`. If you split out human-only work, the
     body also names each follow-up issue (`Human-only items moved to #M`).
