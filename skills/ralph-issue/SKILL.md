---
name: ralph-issue
description: Run one GitHub issue through the ralph loop the way `ralph run <issue>` does, but inside this Claude Code session. Each phase (build → review → merge) runs as its own fresh subagent, and the agents the phase instructions call for (investigator, planner, reviewers) are spawned too. Use when the user types /ralph-issue N or asks to "ralph issue N".
argument-hint: <issue-number> [interactive] [escalate] [build|review|merge]
disable-model-invocation: true
---

# Ralph loop for one issue: `$ARGUMENTS`

You are the orchestrator. You do the job `ralph run` does for a single issue, and nothing else.
You don't read code or diffs and you don't do the steps yourself. Every phase runs in a fresh
subagent, the way `ralph run` starts a fresh `claude` process for each phase. The progress file
`logs/issue-N.progress.md` is the only hand-off between phases.

## 1. Arguments

- First token: the issue number (`N` below). Missing or not a number → stop and ask for one.
- Models, from `ralph config`: the `build` agent uses `RALPH_MODEL` (`RALPH_ESCALATE_MODEL` if
  `escalate` was given); the `review` and `merge` agents use `RALPH_CHEAP_MODEL`.
- A phase name (`build`, `review` or `merge`) → run only that phase. Otherwise run all three, in order.
- `interactive` → phase agents bring decisions to the user (see step 5). The default is the
  loop's hands-off behavior.

## 2. Pre-flight (the same checks as `ralph run`, in one Bash call)

- `ralph config` — note `RALPH_REPO`, `RALPH_BRANCH_PREFIX`, `RALPH_LOCK_LABEL` and the models.
- Use REST only (`gh api repos/{owner}/{repo}/...`): cloud sessions block GraphQL. Run
  `gh api repos/{owner}/{repo}/issues/N` (`.state`, `.title`, `.body`, `.labels[].name`):
  - closed → report and stop;
  - labeled `needs-human` or `blocked` → report and stop;
  - labeled with the lock label → another ralph run holds it: report and stop;
  - otherwise it's open.
- Lock it: `gh api repos/{owner}/{repo}/issues/N/labels -f 'labels[]=<lock label>'` (remove it in
  step 7, whatever the outcome).
- `WT=$(ralph worktree create N)` and note the path `WT`. All work happens there.
- `cd "$WT" && ralph progress pull N`.

## 3. Run each phase as a subagent

For each phase, write its instructions to a file first: `ralph prompt <phase> N > "$WT/logs/issue-N.<phase>.prompt.md"`.
Then spawn **one** `general-purpose` Agent with the chosen `model` and
`description: "ralph #N <phase>"`, with this prompt:

````
Read <WT>/logs/issue-N.<phase>.prompt.md and execute it. It is the full prompt `ralph run` would
give you.

Work only inside <WT>: start every Bash command with `cd <WT> &&` and give Read/Edit absolute
paths under <WT>.

## Running as a subagent

You cannot launch agents yourself. Wherever the instructions say to spawn an Agent, do this
instead: write the progress file, then end your reply with one block per agent to launch, and stop:

AGENT_REQUEST type=<subagent_type>
<the full prompt that agent should get>
END_AGENT_REQUEST

Put agents that should run in parallel (such as the Standards and Spec reviewers) in the same
reply. Their replies come back to you in a message, labeled by type. Continue the step from
exactly where you stopped.

<interactive only> Where the instructions say "If blocked", or where a real design choice comes
up that the issue doesn't settle, don't label the issue yet. End your reply with
`DECISION_NEEDED: <question with options>` and stop. The answer comes back in a message.
Before the merge in step 10, end with `DECISION_NEEDED: merge PR <url>? CI: <result>`.

When the phase is finished (or you stopped under "If blocked"), end with
`PHASE_DONE: <one line: outcome and the progress file's next: line>`.
````

## 4. Relay loop (inside one phase)

Read the phase agent's last reply:

- **`AGENT_REQUEST` blocks** → launch every requested agent **in one message**, so they run in
  parallel, with the requested `subagent_type` and prompt. Then load `SendMessage` (ToolSearch
  `select:SendMessage`) and send the combined replies to the **same** phase agent, one section
  per agent (`## <type> reply` then the reply). Don't read or judge the replies yourself.
- **`DECISION_NEEDED`** (interactive only) → ask the user with AskUserQuestion. Send the answer
  back with SendMessage.
- **`PHASE_DONE`** or anything else → the phase is over. Go to step 6.

Cap each phase at 8 relays. If a phase still isn't done after that, treat it as stuck: stop and
report.

## 5. Interactive vs default

- **Default:** the same as `ralph run`. Nothing is asked. "If blocked" means the phase agent
  adds `needs-human`, posts a comment, and stops. The merge happens as soon as CI is green.
- **`interactive`:** the steps and the agents are the same. The only difference is that the
  `DECISION_NEEDED` points from step 3 go to the user.

## 6. After each phase (the same check as `ralph run`)

Run `gh api repos/{owner}/{repo}/issues/N --jq '{state, labels: [.labels[].name]}'`.

- **Closed** → stop. The issue is done, or it was found already done.
- **`needs-human` or `blocked`** → stop. Quote the comment that ralph posted.
- **Open** → if the next phase is `review` and `<WT>/logs/issue-N.progress.md` has a line starting
  `next: step 10`, the build already did the small review: skip to `merge`. If the next phase is
  `merge` and not `interactive`, first run `cd "$WT" && ralph merge N`: exit 0 means merged, so
  go to step 7; otherwise spawn the merge agent. Otherwise spawn the next phase's agent, fresh.
  If that was the last phase you were asked to run, stop.

## 7. Clean up and report

- Remove the lock: `gh api -X DELETE repos/{owner}/{repo}/issues/N/labels/<lock label>`.
- Issue closed → `ralph worktree remove N`. Otherwise keep the worktree and give its path.

Report: the issue state; the PR
(`gh api "repos/{owner}/{repo}/pulls?head={owner}:<prefix>N&state=all" --jq '.[] | {number, state, html_url}'`);
which phases ran, and each phase's `PHASE_DONE` line. If the issue isn't closed, also include the
progress file and the command to resume: `/ralph-issue N [<phase>]`.
