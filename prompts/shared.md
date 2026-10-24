# Ralph Task Execution Instructions

For the given GitHub Issue number, title, and body description, execute the steps below for
the **phase** named in your prompt. The prompt holds this shared part plus your phase's steps
(`build`, `review`, `merge`; `build` also gets the review steps 8-9 for the small-diff case) and
the project's notes at the end. Don't look for the prompt files: everything you need is here.

## Phases

`ralph run` runs each issue as three separate sessions, each starting with a fresh context,
inside the issue's own git worktree (`.ralph/wt/issue-<ISSUE_NUMBER>`, already on branch
`{{BRANCH_PREFIX}}<ISSUE_NUMBER>`). Never `git checkout` or `git switch` another branch there:
`{{BASE_BRANCH}}` is checked out in the main tree. The progress file is the only hand-off between
sessions, and is mirrored to a GitHub issue comment so a run on another machine can resume, so
keep it accurate.

The ralph command is `"{{RALPH}}"`. Its helpers used below: `progress push <N>`, `checks`,
`merge <N>`.

## Environment
- In cloud sessions use `gh api` REST; GraphQL is blocked. (HTTP 403; every `gh issue|pr <subcommand>` uses it.)

`gh` below means REST: `gh api repos/{owner}/{repo}/...` (`gh` fills in `{owner}/{repo}` itself;
the repo is `{{REPO}}`). Shorthand used below (`R` = `repos/{owner}/{repo}`):

- issue: `gh api R/issues/N` (`.state`, `.labels[].name`, `.body`)
- labels: `gh api R/issues/N/labels -f 'labels[]=x'` (add), `gh api -X DELETE R/issues/N/labels/x` (remove)
- comment / close: `gh api R/issues/N/comments -f body=…`, `gh api -X PATCH R/issues/N -f state=closed`
- PR for the branch: `gh api "R/pulls?head=<owner>:<branch>&state=all"`
- open a PR: `gh api R/pulls -f head=<branch> -f base={{BASE_BRANCH}} -f title=… -F body=@<file>`
- CI: `gh api R/commits/<sha>/check-runs` (all `completed` and `conclusion` success/neutral/skipped = green)
- merge: `gh api -X PUT R/pulls/N/merge -f merge_method={{MERGE_METHOD}}`
- agents: use `{{REVIEWER_AGENT}}` for reviewers and `{{INVESTIGATOR_AGENT}}` for searches; if
  that type is not available, use `general-purpose` with the same prompt.

| Phase    | Steps   | End your turn when                                                  |
| -------- | ------- | ------------------------------------------------------------------- |
| `build`  | 0 – 7 (+ 8, 9 if small) | the PR is open and the progress file says `next: step 8` (or `next: step 10` if you did the small review) |
| `review` (cheap model) | 0, 8, 9 | review fixes are pushed, checklist updated, `next: step 10`         |
| `merge` (cheap model)  | 0, 10, 11 | the issue is closed (`step: done`)                                |

The loop merges green PRs itself (`ralph merge`). A `merge` session starts only when that
failed: CI is red, there is no open PR, or the merge was refused.

- Always start with step 0. If the progress file shows an **earlier** step unfinished (e.g. the
  previous phase died mid-way), finish it first, then do this phase's steps.
- **Run everything in the foreground, then end the phase.** Run tests, reviewers (sub-agents) and
  `git push` in the foreground and wait for them; never in the background (an ended turn restarts
  the session and reloads the whole context). Never poll or wait for CI (`gh pr checks --watch`,
  `gh api` loops) and never `sleep`: the loop waits for CI and merges. Once the PR is pushed and
  the progress file is updated, end your turn. If a command fails because it wanted input (a
  credential prompt), do not retry it in a loop: report it under "If blocked".
- Do not start steps belonging to a later phase — end your turn so the next phase starts fresh.
- Exception: in `build`, after step 7 always size the diff (step 8). If it is **small**, do
  steps 8 and 9 in the same session and set `next: step 10` (not `next: step 8`); the loop
  then skips the `review` phase. Stopping at `next: step 8` for a small diff wastes a whole
  review session.
- The issue closing early (step 2 "all met" or "only struck items remain") or "If blocked" ends
  every phase. Splitting out human-only work does **not** end a phase.

**The issue body is the spec and the scope.** Its acceptance criteria are the work; everything
else is derived from it. The project's spec doc is `{{SPEC_DOC}}` (`none`: there is none): read
only the sections of it the body names, and only the files/symbols its criteria point to. Don't
explore beyond that.

0. **Resume Check** (always first):
   - If `logs/issue-<ISSUE_NUMBER>.progress.md` exists, read it (the loop pulled it from the
     issue comment) — it says which step you stopped at, what's done, what's next, and decisions
     already made. Trust it over re-deriving.
   - Look up the PR: `gh api "repos/{owner}/{repo}/pulls?head=<owner>:{{BRANCH_PREFIX}}<ISSUE_NUMBER>&state=all" --jq '.[] | {number, state, html_url}'`.
   - If an **open** PR exists: you are already on its branch. Continue from the `next:` line of the
     progress file (no progress file → read the PR's comments via `gh api repos/{owner}/{repo}/issues/<PR>/comments` to see what was done).
   - Otherwise (no PR, or only a merged one) go to step 1.

## Progress file

At the end of **every** step, overwrite `logs/issue-<ISSUE_NUMBER>.progress.md` (max ~20 lines)
and mirror it to the issue in the same Bash call:
`"{{RALPH}}" progress push <ISSUE_NUMBER>`.

```
step: 8 (code review) — in progress
branch: {{BRANCH_PREFIX}}<ISSUE_NUMBER>   PR: #41
audit: 3/5 met on {{BASE_BRANCH}} (checked); missing: onboarding test, permission test
done: plan, tests (12 passing), local checks green, PR opened
review findings: 1 fixed (XSS in source_url), 1 open (rename fakeClient → ...)
split: #92 (human-only items moved out, if any)
next: fix open finding, re-run checks, push
decisions: chose X over Y because ...
```

Keep `decisions` to choices git can't show. When the issue is closed, set `step: done`.

## Human-only work → split out

Use this when a criterion truly needs a human: secrets/credentials you can't create, hosted
dashboard or account steps, subjective product sign-off. Do **not** label the current issue
`needs-human`; finish everything else and move the human part to its own issue. Apply it
whenever you meet such a criterion (step 2 audit or later), then carry on with the normal phases.

**Not human-only:** device, browser and visual checks. Do them yourself with the project's tooling
(see the project notes) and report what you saw. Split only after an honest attempt failed.

- A criterion that can be asserted (element visible, link `href`, row not selected): commit it as
  an end-to-end test, using the project's existing helpers.
- A purely visual criterion: in a throwaway script (not committed) check phone width (~390px) and
  desktop width, each in light and dark mode. Take screenshots, open them with Read, and write
  what you saw in the PR.
- Split a browser check to `needs-human` only after the run failed. Paste the failure output into
  the new issue.

**Tool-first check** before calling anything human-only. Look for something that can do the job:
tools, MCP servers and skills already in the session, a CLI (`gh`, cloud CLIs, …),
`SearchSkills` / `SearchPlugins`, the MCP registry (`search_mcp_registry`, `suggest_connectors`).

- **Tool available now** → use it and do the job. No split.
- **Tool exists but is not installed** → open a separate `needs-human` issue
  `Install <tool> so ralph can <do X>` with: what the tool is, why it is needed, exact
  install/auth steps, which original item it unlocks, and a last step "after install, close
  this issue; ralph then performs <X>". Strike the original line as
  `- [ ] ~~text~~ → needs <tool> (#K), then ralph does it`. Create the job as another issue with
  `## Blocked by #K`, **not** labeled `needs-human`, so the loop picks it up once #K is closed.
- **No tool exists** → human-only. Split as below.
- Search before you create (`gh api -X GET search/issues -f q="repo:{{REPO}} <title words> in:title"`) so a resumed
  phase opens no duplicates.

**Split:**

1. Refetch the body: `gh api repos/{owner}/{repo}/issues/<ISSUE_NUMBER> --jq .body > logs/issue-<ISSUE_NUMBER>.body.md`.
2. Strike each human-only checklist line, keeping it: `- [ ] ~~text~~ → moved to #M`.
3. Create the new issue **once**. First check the progress file for `split: #M` and
   `gh api -X GET search/issues -f q="repo:{{REPO}} Split from #<ISSUE_NUMBER> in:body"`; reuse a hit. Else
   `gh api repos/{owner}/{repo}/issues -f 'labels[]=needs-human' -f title="[needs-human] <parent title>: <short>" -F body=@<file>`.
4. Save the edited body: `gh api -X PATCH repos/{owner}/{repo}/issues/<ISSUE_NUMBER> -F body=@logs/issue-<ISSUE_NUMBER>.body.md`.
5. Record `split: #M` in the progress file.

New-issue body:

```
Split from #<ISSUE_NUMBER> (PR: <link, or "none yet">)

## Already done
<what ralph finished>

## To do (human)
- [ ] <item> — how to verify / next step: <exact command or click path>

## Why ralph couldn't do it
<reason; what was tried>
```

No `## Blocked by` section, and never add this issue to another issue's `## Blocked by`: it is
fully independent and the loop skips it by label. If the item really gates later work, say so in
the issue text so the human sees it.

**Parent completion:** the parent is done when every non-struck criterion is met; struck items
count as handled. Normal phases continue (PR, review, CI, merge, step 11). If only struck items
remain at the step 2 audit, close the parent as described there.

If creating the issue fails, fall back to "If blocked" below instead of dropping the human work.

## If blocked

If the **whole issue** is blocked and cannot be split (a decision only the user can make, a result
that contradicts the spec doc, CI failing for reasons outside this issue, a reviewer mismatch
twice), do **not** merge. Add the label `needs-human` to the issue, post a comment (on the PR if
there is one, else on the issue) with what is done and the exact next step, and end your turn.

## Keep context small (saves tokens)

- Prompts to sub-agents point at sections, not whole files: name the spec doc heading and the step
  numbers they need.
- Read only the sections of the spec doc the issue body names (`grep -n "^##" <doc>`, then
  `sed -n` the relevant range).
- Never read old session transcripts (`~/.claude/projects/**/*.jsonl`); use step 0 to resume.
- Exclude lockfiles from diffs: `git diff {{BASE_BRANCH}}...HEAD -- . {{DIFF_EXCLUDE}}`.
- Pipe noisy output through `tail` (installs, test runs, CI logs) and chain related commands in
  one Bash call instead of many small ones.
- Budget: a `build` session should finish in about 20 turns. Most of the cost is in builds with
  30+ turns, because each turn re-sends the whole context.
- **Batch tool calls — this is required, not a suggestion.** Every turn re-sends the whole
  context, so the number of turns is the main cost. Whenever you need several reads, greps or
  independent commands, issue them **all in one message** as parallel tool calls. A turn with a
  single Read followed by another single Read is a mistake.
- Read each file **once**. Don't re-read a file after editing it — the Edit succeeded or errored.
  Don't re-read a spec section you already have; note what you need in the progress file.
