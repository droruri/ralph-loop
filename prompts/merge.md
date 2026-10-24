10. **Wait for CI, then Merge**:
    - Prefer `"{{RALPH}}" merge <ISSUE_NUMBER>`: it waits for CI, merges, closes the issue and
      unblocks dependents (all REST). Exit 0 → set `step: done`.
    - If CI is red: read the failing log (`gh api repos/{owner}/{repo}/actions/runs/<RUN_ID>/jobs`,
      then `.../actions/jobs/<JOB_ID>/logs | tail -80`), fix, push, and run the command again.
    - Merge by hand only if the command cannot: `gh api -X PUT repos/{owner}/{repo}/pulls/<PR>/merge -f merge_method={{MERGE_METHOD}}`
      once CI is green (the branch is checked out in this worktree; the loop removes it).

11. **Unblock Dependent Tasks**:
    - `ralph merge` does this. By hand: list open issues labeled `blocked`
      (`gh api "repos/{owner}/{repo}/issues?state=open&labels=blocked"`) whose body mentions
      `#<ISSUE_NUMBER>`, and remove the `blocked` label only if **every** issue under its
      `## Blocked by` is now closed.
