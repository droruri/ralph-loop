# ralph-loop

Run your GitHub issues through Claude Code, one after another, hands-off.

`ralph run` takes the oldest issue that isn't blocked and runs it as three fresh `claude`
sessions in its own git worktree:

1. **build**: check what's already done, plan, write tests and code, run checks, open a PR (and
   review it in the same session if the diff is small);
2. **review**: reviewer agents read the diff, and the session fixes what they find;
3. **merge**: waits for CI and merges. This step is plain shell; a session runs only if CI is red
   or the merge fails.

Then it moves to the next issue. A progress file, mirrored to an issue comment, is the hand-off
between phases, so a run can resume on any machine. Issues are locked with a label, so two runs
never take the same one.

## Install

Pick one:

```sh
# Node projects: a dev dependency, run with npx / pnpm exec
pnpm add -D github:droruri/ralph-loop        # or npm i -D github:droruri/ralph-loop

# Any project: once per machine, puts `ralph` in ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/droruri/ralph-loop/main/install.sh | bash
```

Pin a version with `#v0.1.0` (npm) or `RALPH_REF=v0.1.0` (install.sh).

Needs: bash 4.2+ (on macOS: `brew install bash`), git 2.31+, jq, the `gh` CLI (logged in), and
Claude Code (`claude`, logged in to claude.ai).

## Use

```sh
ralph init              # .ralphrc, ralph/project.md, .gitignore entries, labels
ralph next              # which issue would run next
ralph run               # work through every unblocked issue
ralph run 12            # just #12
RALPH_MODEL=opus ralph run 12
```

How issues should look:

- Write each issue's acceptance criteria as a checklist (`- [ ] …`). The body is the spec.
- List blockers as `#N` under a `## Blocked by` heading. An issue waits until they are all closed.
- Labels: `blocked` (waits on another issue), `needs-human` (ralph skips it), `ralph:running`
  (the lock; remove it if a run died).

## Configure

`.ralphrc` in the project root (`KEY=value` lines). Environment variables win over it.

| Key | Default | What |
| --- | --- | --- |
| `RALPH_REPO` | from `origin` | `owner/repo` |
| `RALPH_BASE_BRANCH` | `main` | PR target |
| `RALPH_BRANCH_PREFIX` | `feature/issue-` | branch per issue |
| `RALPH_MERGE_METHOD` | `squash` | `squash`, `merge` or `rebase` |
| `RALPH_MODEL` | `sonnet` | build phase |
| `RALPH_CHEAP_MODEL` | `haiku` | review and merge phases |
| `RALPH_ESCALATE_MODEL` | `opus` | one more pass if the issue is still open; empty = off |
| `RALPH_TOOLS` | `Bash,Read,Edit,Write,Skill,Agent` | tools the sessions load |
| `RALPH_PLUGINS` | (none) | comma-separated plugin ids to enable |
| `RALPH_SPEC_DOC` | `none` | design doc the issues point into |
| `RALPH_PLAN_SKILL` | `none` | skill a sub-agent runs to plan |
| `RALPH_TDD_SKILL` | `none` | skill the build runs for red → green |
| `RALPH_REVIEWER_AGENT` | `general-purpose` | agent type for reviewers |
| `RALPH_INVESTIGATOR_AGENT` | `general-purpose` | agent type for searches |
| `RALPH_INSTALL_CMD` | `auto` | worktree setup; `auto` = from the lockfile, empty = skip |
| `RALPH_CHECKS_CMD` | `auto` | `ralph checks`; `auto` = package.json `lint`, `typecheck`, `test` |
| `RALPH_LINK_FILES` | `.env` | linked from the main checkout into each worktree |
| `RALPH_PROMPTS_DIR` | `ralph` | where prompt overrides live |
| `RALPH_LOGS_DIR` | `logs` | session logs and the cost ledger (`ralph-costs.tsv`) |

`ralph config` prints the resolved values.

### Prompts

Each phase gets `prompts/shared.md` + `prompts/<phase>.md` (build also gets `review.md`), then
your `ralph/project.md`. Put what's special about your project in `project.md`: how to run one test
file, browser checks, local services. Keep it short; it's re-sent on every turn.

To change a step itself, `ralph init --prompts` copies the defaults into `ralph/`; a file there
replaces the default. `{{BASE_BRANCH}}`, `{{RALPH}}`, `{{DIFF_EXCLUDE}}` and the other
placeholders are filled from the config. `ralph prompt build 12` prints exactly what a session
would get.

### Claude Code skill

`ralph init --skills` installs `/ralph-issue N`: the same loop for one issue, run inside an open
Claude Code session with each phase as a subagent (add `interactive` to be asked at decisions).

## Commands

```
ralph run [issue]                 the loop
ralph next                        next unblocked issue
ralph prompt <phase> [issue]      composed instructions
ralph progress pull|push <issue>  progress file ⇄ issue comment
ralph worktree create|remove <issue>
ralph checks                      local checks
ralph merge <issue>               wait for CI, merge, close, unblock dependents
ralph init [--prompts] [--skills]
ralph config | version
```

## Develop

```sh
bash tests/run.sh          # fake gh and claude; no network
bash tests/run.sh merge    # only matching tests
npm run lint               # shellcheck
```

Layout: `bin/ralph` dispatches to `lib/cmd/<command>.sh`; shared code is in `lib/*.sh`; default
prompts in `prompts/`; files `init` copies in `templates/` and `skills/`.

## Roadmap

A real CLI (`npx ralph-loop`) will replace the bash entry point. It will keep the same commands,
`.ralphrc` keys and prompt files, so projects won't need to change anything.
