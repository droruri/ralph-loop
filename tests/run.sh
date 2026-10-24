#!/usr/bin/env bash
# Tests for ralph. No network, no real claude: gh and claude are the fakes in tests/stubs.
#
#   bash tests/run.sh            all tests
#   bash tests/run.sh merge      only tests whose name contains "merge"

set -uo pipefail

LIB=$(cd "$(dirname "$0")/.." && pwd)
RALPH="$LIB/bin/ralph"
FILTER="${1:-}"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
pass=0
fail=0

# Every test runs in a subshell with: a bare origin, a clone of it with one commit on main (cwd),
# RALPH_REPO=o/r, and the fake gh/claude first on PATH.
setup() {
  T="$TMP_ROOT/$1"
  mkdir -p "$T/fixtures"
  export GH_FIXTURES="$T/fixtures" GH_LOG="$T/gh.log" CLAUDE_ARGS="$T/claude.args" CLAUDE_CWD="$T/claude.cwd"
  export PATH="$LIB/tests/stubs:$PATH"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  # The tests' own environment must not leak in.
  unset "${!RALPH_@}"
  : > "$GH_LOG"
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/project" 2> /dev/null
  cd "$T/project" || exit 1
  git commit -q --allow-empty -m init
  git push -q origin main 2> /dev/null
  echo 'RALPH_REPO=o/r' > .ralphrc
}

fixture() {
  cat > "$GH_FIXTURES/$1"
}

fail() {
  echo "    FAIL: $*"
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_contains() {
  grep -qF -- "$2" <<< "$1" || fail "expected to contain '$2'; got:
$1"
}

assert_not_contains() {
  ! grep -qF -- "$2" <<< "$1" || fail "expected not to contain '$2'"
}

run_test() {
  local name=$1
  [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return
  if (setup "$name" && "$name") > "$TMP_ROOT/$name.out" 2>&1; then
    pass=$((pass + 1))
    echo "ok   $name"
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    sed 's/^/    /' "$TMP_ROOT/$name.out"
  fi
}

# --- config ---------------------------------------------------------------------------------

test_repo_from_remote() {
  # shellcheck disable=SC1091
  . "$LIB/lib/common.sh"
  local url
  for url in https://github.com/own/rep.git git@github.com:own/rep.git \
    http://proxy@127.0.0.1:1234/git/own/rep https://github.com/own/rep/; do
    git remote set-url origin "$url"
    assert_eq "$(ralph_repo_from_remote .)" own/rep
  done
}

test_config_env_wins_over_ralphrc() {
  printf 'RALPH_MODEL=sonnet\nRALPH_BASE_BRANCH=develop\n' >> .ralphrc
  local out
  out=$(RALPH_MODEL=opus "$RALPH" config)
  assert_contains "$out" "RALPH_MODEL=opus"
  assert_contains "$out" "RALPH_BASE_BRANCH=develop"
  assert_contains "$out" "RALPH_REPO=o/r"
}

test_config_empty_value_disables_default() {
  echo 'RALPH_ESCALATE_MODEL=' >> .ralphrc
  assert_contains "$("$RALPH" config)" "RALPH_ESCALATE_MODEL=''"
}

# --- prompts --------------------------------------------------------------------------------

test_prompt_fills_every_placeholder() {
  local phase out
  for phase in build review merge; do
    out=$("$RALPH" prompt "$phase")
    assert_not_contains "$out" "{{"
  done
  out=$("$RALPH" prompt build)
  assert_contains "$out" "\"$LIB/bin/ralph\" checks"
  assert_contains "$out" "feature/issue-<ISSUE_NUMBER>"
  assert_contains "$out" "git diff main...HEAD -- . ':!*-lock.yaml'"
}

test_prompt_build_includes_review_steps() {
  assert_contains "$("$RALPH" prompt build)" "8. **Code Review Phase**"
  assert_not_contains "$("$RALPH" prompt merge)" "8. **Code Review Phase**"
}

test_prompt_project_override_and_notes() {
  mkdir -p ralph
  echo 'CUSTOM MERGE STEPS on {{BASE_BRANCH}} & co' > ralph/merge.md
  echo '## Project notes: use pnpm' > ralph/project.md
  echo 'RALPH_BASE_BRANCH=trunk' >> .ralphrc
  local out
  out=$("$RALPH" prompt merge)
  assert_contains "$out" "CUSTOM MERGE STEPS on trunk & co"
  assert_contains "$out" "## Project notes: use pnpm"
  assert_not_contains "$out" "10. **Wait for CI"
  assert_contains "$out" "# Ralph Task Execution Instructions"
}

test_prompt_for_issue_has_title_body_and_worktree() {
  fixture GET_repos_o_r_issues_7 <<< '{"number":7,"title":"Add login","body":"- [ ] it works"}'
  local out
  out=$("$RALPH" prompt build 7)
  assert_contains "$out" "Execute PHASE build of the ralph instructions below for Issue #7."
  assert_contains "$out" "ISSUE TITLE: Add login"
  assert_contains "$out" "- [ ] it works"
  assert_contains "$out" ".ralph/wt/issue-7, already on branch feature/issue-7"
}

# --- issue selection ------------------------------------------------------------------------

open_issues_fixture() {
  fixture GET_repos_o_r_issues_state_open_per_page_100 << 'EOF'
[
  {"number": 2, "title": "a PR", "body": "", "labels": [], "pull_request": {}},
  {"number": 3, "title": "human", "body": "", "labels": [{"name": "needs-human"}]},
  {"number": 4, "title": "waits on 5", "body": "x\n## Blocked by\n- #5\n", "labels": [{"name": "blocked"}]},
  {"number": 6, "title": "was blocked on closed 1", "body": "## Blocked by\n- #1\n\n## Notes\nsee #5", "labels": [{"name": "blocked"}]},
  {"number": 8, "title": "free", "body": null, "labels": []},
  {"number": 5, "title": "free, oldest", "body": "## Blocked by\nnone, see #1", "labels": []},
  {"number": 9, "title": "locked", "body": "", "labels": [{"name": "ralph:running"}]}
]
EOF
}

test_next_picks_oldest_unblocked() {
  open_issues_fixture
  assert_eq "$("$RALPH" next)" 5
}

test_next_prints_nothing_when_none() {
  fixture GET_repos_o_r_issues_state_open_per_page_100 <<< '[]'
  assert_eq "$("$RALPH" next)" ""
}

test_merge_green_merges_and_unblocks() {
  open_issues_fixture
  fixture GET_repos_o_r_pulls_head_o_feature_issue_1_state_open <<< '[{"number": 40, "head": {"sha": "abc"}}]'
  fixture GET_repos_o_r_commits_abc_check_runs_per_page_100 <<< '{"check_runs": [{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "skipped"}]}'
  fixture GET_repos_o_r_commits_abc_status <<< '{"total_count": 0, "state": "pending"}'
  fixture GET_repos_o_r_issues_1 <<< '{"state": "open"}'
  local out
  out=$("$RALPH" merge 1) || fail "merge exited non-zero: $out"
  assert_contains "$out" "PR #40 merged; issue #1 closed."
  local log
  log=$(cat "$GH_LOG")
  assert_contains "$log" "api -X PUT repos/o/r/pulls/40/merge -f merge_method=squash"
  assert_contains "$log" "api -X PATCH repos/o/r/issues/1 -f state=closed"
  # #6 waits only on closed #1 (the "#5" under ## Notes doesn't count); #4 still waits on open #5.
  assert_contains "$log" "api -X DELETE repos/o/r/issues/6/labels/blocked"
  assert_not_contains "$log" "issues/4/labels/blocked"
}

test_merge_red_ci_does_not_merge() {
  fixture GET_repos_o_r_pulls_head_o_feature_issue_1_state_open <<< '[{"number": 40, "head": {"sha": "abc"}}]'
  fixture GET_repos_o_r_commits_abc_check_runs_per_page_100 <<< '{"check_runs": [{"status": "completed", "conclusion": "failure"}]}'
  fixture GET_repos_o_r_commits_abc_status <<< '{"total_count": 0}'
  local out
  out=$("$RALPH" merge 1) && fail "merge should fail on red CI"
  assert_contains "$out" "CI is not green on PR #40 (red)."
  assert_not_contains "$(cat "$GH_LOG")" "merge -f"
}

test_merge_status_only_ci_counts_as_green() {
  open_issues_fixture
  fixture GET_repos_o_r_pulls_head_o_feature_issue_1_state_open <<< '[{"number": 40, "head": {"sha": "abc"}}]'
  fixture GET_repos_o_r_commits_abc_check_runs_per_page_100 <<< '{"check_runs": []}'
  fixture GET_repos_o_r_commits_abc_status <<< '{"total_count": 1, "state": "success"}'
  fixture GET_repos_o_r_issues_1 <<< '{"state": "closed"}'
  "$RALPH" merge 1 > /dev/null || fail "status-only green CI should merge"
}

test_merge_without_pr_fails() {
  fixture GET_repos_o_r_pulls_head_o_feature_issue_1_state_open <<< '[]'
  local out
  out=$("$RALPH" merge 1) && fail "merge should fail without a PR"
  assert_contains "$out" "No open PR for feature/issue-1."
}

# --- worktree and progress ------------------------------------------------------------------

test_worktree_create_and_remove() {
  echo 'SECRET=1' > .env
  local wt
  wt=$("$RALPH" worktree create 12 2> /dev/null)
  assert_eq "$wt" "$PWD/.ralph/wt/issue-12"
  assert_eq "$(git -C "$wt" branch --show-current)" feature/issue-12
  [ -L "$wt/.env" ] || fail ".env not linked"
  # Reuses it, also when called from inside the worktree.
  assert_eq "$(cd "$wt" && "$RALPH" worktree create 12 2> /dev/null)" "$wt"
  "$RALPH" worktree remove 12
  [ ! -d "$wt" ] || fail "worktree not removed"
  git show-ref --verify --quiet refs/heads/feature/issue-12 && fail "branch not deleted"
  true
}

test_progress_push_creates_then_pull_reads() {
  fixture GET_repos_o_r_issues_3_comments <<< '[]'
  mkdir -p logs
  printf 'step: 5\nnext: step 6\n' > logs/issue-3.progress.md
  "$RALPH" progress push 3
  assert_contains "$(cat "$GH_LOG")" "api repos/o/r/issues/3/comments -F body=@"

  # shellcheck disable=SC2016
  fixture GET_repos_o_r_issues_3_comments <<< '[{"id": 77, "body": "<!-- ralph-progress -->\n```text\nstep: 9\n```"}]'
  # shellcheck disable=SC2016
  fixture GET_repos_o_r_issues_comments_77 <<< '{"body": "<!-- ralph-progress -->\n```text\nstep: 9\nnext: step 10\n```"}'
  "$RALPH" progress pull 3
  assert_eq "$(cat logs/issue-3.progress.md)" "step: 9
next: step 10"
}

# --- init -----------------------------------------------------------------------------------

test_init_is_rerunnable_and_never_overwrites() {
  rm .ralphrc
  fixture GET_repos_o_r <<< '{"full_name": "o/r"}'
  git remote set-url origin https://github.com/o/r.git
  "$RALPH" init --prompts --skills > /dev/null || fail "init failed"
  [ -f .ralphrc ] && [ -f ralph/project.md ] && [ -f ralph/build.md ] || fail "files missing"
  [ -f .claude/skills/ralph-issue/SKILL.md ] || fail "skill missing"
  echo 'mine' > ralph/project.md
  "$RALPH" init > /dev/null
  assert_eq "$(cat ralph/project.md)" mine
  assert_eq "$(grep -cxF .ralph/ .gitignore)" 1
}

# --- the loop -------------------------------------------------------------------------------

test_run_closed_issue_does_nothing() {
  fixture GET_repos_o_r_issues_4 <<< '{"number": 4, "state": "closed", "labels": []}'
  local out
  out=$(RALPH_CLAUDE=claude "$RALPH" run 4) || fail "should exit 0: $out"
  assert_contains "$out" "Issue #4 is closed. Nothing to run."
  [ ! -f "$CLAUDE_ARGS" ] || fail "claude ran"
}

test_run_one_issue_end_to_end() {
  # Open for the pre-flight checks and the fetch; closed after the build phase.
  fixture GET_repos_o_r_issues_5.1 <<< '{"number": 5, "title": "Add login", "body": "- [ ] works", "state": "open", "labels": []}'
  fixture GET_repos_o_r_issues_5.4 <<< '{"number": 5, "title": "Add login", "body": "- [ ] works", "state": "closed", "labels": []}'
  fixture GET_repos_o_r_issues_5_comments <<< '[]'
  echo 'RALPH_PLUGINS="caveman@caveman, other@x"' >> .ralphrc
  local out
  out=$("$RALPH" run 5 2>&1) || fail "run failed: $out"
  assert_contains "$out" "fake build done"
  assert_contains "$out" "phase done: 3 turns, \$0.25, 4s"
  assert_contains "$out" "---> Issue #5 closed."
  local args
  args=$(cat "$CLAUDE_ARGS")
  assert_contains "$args" "Execute PHASE build of the ralph instructions below for Issue #5."
  assert_contains "$args" '{"disableAllHooks":true,"enabledPlugins":{"caveman@caveman":true,"other@x":true}}'
  assert_eq "$(cat "$CLAUDE_CWD")" "$PWD/.ralph/wt/issue-5"
  assert_contains "$(cat logs/ralph-costs.tsv)" "$(printf '5\tbuild\tsonnet\t3\t0.25\t4\tfalse')"
  local log
  log=$(cat "$GH_LOG")
  assert_contains "$log" "api repos/o/r/issues/5/labels -f labels[]=ralph:running"
  assert_contains "$log" "api -X DELETE repos/o/r/issues/5/labels/ralph:running"
  [ ! -d .ralph/wt/issue-5 ] || fail "worktree kept for a closed issue"
}

for t in $(compgen -A function test_); do
  run_test "$t"
done
echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
