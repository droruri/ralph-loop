**Review scope (the `review` phase, run on the cheap model).** The phase relays reviewer
findings and fixes them. Nothing else. The `build` session, when it runs steps 8-9 itself, is
not bound by this block.
   - Allowed: spawn the reviewers, fix their findings, run step 6, push, flip the checklist.
   - Not allowed: browser checks or any other ad-hoc script (shell, node, python) written to
     verify behavior, edits to the ralph prompts (`{{PROMPTS_DIR}}/`), ralph config (`.ralphrc`)
     or `.claude/skills/` (unless the issue itself is about the ralph loop), and work on anything
     the findings and acceptance criteria do not name.
   - A criterion that needs a browser or device check: do not do it. Add the line
     `needs browser check: <criterion and what to look at>` to the progress file, leave its
     checklist box unchecked, and go on. The escalation pass or a human does that check.
   - Turn budget: **25 turns**. Spawning the reviewers, fixing and pushing fit well inside it. At
     turn 20, stop adding fixes: push what passes step 6, record the unfixed findings in the
     progress file under `review findings:` (`open: …`), set `next: step 10`, and end your turn.

8. **Code Review Phase**:
   - Size the diff: `git diff --shortstat {{BASE_BRANCH}}...HEAD -- . {{DIFF_EXCLUDE}}`.
   - **Small (under ~150 changed lines):** one `{{REVIEWER_AGENT}}` Agent covering both axes
     (Standards = the project's conventions in `CLAUDE.md` / `AGENTS.md`, Spec = every acceptance
     criterion). In `build`, do this right after step 7 (see "Phases").
   - **Otherwise:** two `{{REVIEWER_AGENT}}` Agents **in one message** (parallel), one
     Standards, one Spec. Spawn them directly — don't load a code-review skill into your context;
     it would ride along on every later turn.
   - Give every reviewer: the issue number, the acceptance criteria (copied, not paraphrased), the
     diff command `git diff {{BASE_BRANCH}}...HEAD -- . {{DIFF_EXCLUDE}}`, and these limits:
     *"Run the diff command once. Open another file only to confirm a finding you already suspect
     from the diff — no exploring. At most ~10 tool calls. One line per finding; none → `no findings`."*
   - Do **not** read the diff yourself (no `git diff` output, no diff file in `/tmp`). You only
     take in the findings, then open just the hunks you need to fix.
   - Guard against a reviewer reviewing the wrong thing: tell each reviewer to start its reply with
     `issue #<ISSUE_NUMBER>` and the file list from `git diff --stat {{BASE_BRANCH}}...HEAD -- . {{DIFF_EXCLUDE}}`.
     Compare that list with `git diff --name-only {{BASE_BRANCH}}...HEAD -- . {{DIFF_EXCLUDE}}` (names only,
     cheap). If it cites another issue or files outside the diff, discard its output and re-run it
     once; a second mismatch → "If blocked". Never record "0 findings" from a mismatched reviewer.
   - Fix any critical bugs or style issues identified during the review, re-run step 6, and push.

9. **Update Issue Checklist in GitHub**:
   - Fetch the current body (`gh api repos/{owner}/{repo}/issues/<ISSUE_NUMBER> --jq .body > logs/issue-<ISSUE_NUMBER>.body.md`
     — it may have changed since your prompt), flip the done items from `- [ ]` to `- [x]`, and
     save it with `gh api -X PATCH repos/{owner}/{repo}/issues/<ISSUE_NUMBER> -F body=@logs/issue-<ISSUE_NUMBER>.body.md`.
   - Leave struck lines (`- [ ] ~~…~~ → moved to #M`) as they are; never flip them to `[x]`.
