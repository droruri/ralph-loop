#!/usr/bin/env bash
# ralph run [issue]: the loop. Takes the oldest unblocked issue, runs it as three fresh `claude`
# sessions (build → review → merge) in its own worktree, and moves on. With an issue number,
# runs just that issue and exits.
#
# The progress comment on the issue is the hand-off between phases (and machines). Context resets
# between phases instead of carrying the whole implementation history into review and CI.

set -eo pipefail
. "$RALPH_LIB/lib/common.sh"
. "$RALPH_LIB/lib/github.sh"
. "$RALPH_LIB/lib/session.sh"

root=$(ralph_project_root) || ralph_die "not inside a git repository"
cd "$root"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
ralph_load_config
ralph_require git gh jq "${RALPH_CLAUDE:-claude}"

# Use the claude.ai login (or CLAUDE_CODE_OAUTH_TOKEN in the cloud), not an API key: a stray key
# bills API credits instead. RALPH_KEEP_API_KEY=1 keeps it.
[ "${RALPH_KEEP_API_KEY:-}" = 1 ] || unset ANTHROPIC_API_KEY

# Non-interactive: a command that would prompt (git credentials, a watch mode) fails at once
# instead of hanging the session. CI=true puts tools in their CI mode.
export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GH_PROMPT_DISABLED=1 CI=true

ONLY_ISSUE="${1:-}"
[ -z "$ONLY_ISSUE" ] || ralph_issue_arg "$ONLY_ISSUE"

RALPH_COST_LEDGER="$RALPH_LOGS_DIR/ralph-costs.tsv"
mkdir -p "$RALPH_LOGS_DIR"
[ -f "$RALPH_COST_LEDGER" ] || printf 'date\tissue\tphase\tmodel\tturns\tcost_usd\tseconds\terror\n' > "$RALPH_COST_LEDGER"
ralph_ensure_labels

LOCKED_ISSUE=""
unlock_issue() {
  if [ -n "$LOCKED_ISSUE" ]; then
    gh api -X DELETE "repos/$RALPH_REPO/issues/$LOCKED_ISSUE/labels/$RALPH_LOCK_LABEL" > /dev/null 2>&1 || true
    LOCKED_ISSUE=""
  fi
}
trap unlock_issue EXIT
trap 'exit 130' INT TERM

progress() {
  (cd "$WORKTREE" && "$RALPH_BIN" progress "$1" "$ISSUE_NUM")
}

# run_phase <phase> <model>: one session, waiting out (up to 3) subscription usage limits.
# The progress comment is pulled before and pushed after every session.
run_phase() {
  local phase=$1 model=$2 wait
  for _ in 1 2 3 4; do
    progress pull
    ralph_run_claude "$phase" "$model" "$ISSUE_NUM" "$WORKTREE" "$ISSUE_TITLE" "$ISSUE_BODY"
    progress push
    [ "$RESETS_AT" = 0 ] && return 0
    wait=$((RESETS_AT - $(date +%s) + 60))
    [ $wait -lt 60 ] && wait=60
    echo "--- Usage limit reached. Sleeping $((wait / 60)) min until it resets, then resuming phase $phase. ---"
    sleep $wait
  done
  echo "--- Still rate-limited after 3 waits. Giving up on phase $phase. ---"
}

# run_phases <model>: build → review → merge, stopping when the issue leaves "open".
run_phases() {
  local model=$1 phase phase_model
  for phase in build review merge; do
    # A small diff is reviewed inside the build phase, which then hands off `next: step 10`.
    if [ "$phase" = review ] && grep -q '^next: step 10' "$WORKTREE/logs/issue-$ISSUE_NUM.progress.md" 2> /dev/null; then
      echo "--- Issue #$ISSUE_NUM: review already done in build, skipping ---"
      continue
    fi
    # Waiting for CI and merging needs no LLM; the merge session runs only when that fails.
    if [ "$phase" = merge ] && "$RALPH_BIN" merge "$ISSUE_NUM"; then
      break
    fi
    # Only build needs the strong model; review and merge relay findings and run commands.
    phase_model=$model
    [ "$phase" != build ] && phase_model=$RALPH_CHEAP_MODEL
    run_phase "$phase" "$phase_model"
    # Closed (found done, or merged), or labeled blocked/needs-human: skip the rest.
    if [ "$(ralph_issue_state "$ISSUE_NUM")" != open ]; then break; fi
  done
}

while true; do
  if [ -n "$ONLY_ISSUE" ]; then
    ISSUE_NUM=$ONLY_ISSUE
    # Don't start on a closed issue, one a human has to look at first, or one another run holds.
    START_STATE=$(ralph_issue_state "$ISSUE_NUM")
    if [ "$START_STATE" != open ]; then
      echo "Issue #$ISSUE_NUM is $START_STATE. Nothing to run."
      [ "$START_STATE" = closed ] && exit 0 || exit 1
    fi
    if [ "$(ralph_is_locked "$ISSUE_NUM")" = true ]; then
      echo "Issue #$ISSUE_NUM has the $RALPH_LOCK_LABEL label: another ralph run is on it. Remove the label if that run died."
      exit 1
    fi
    ISSUE_JSON=$(gh api "repos/$RALPH_REPO/issues/$ONLY_ISSUE" --jq '{number, title, body: (.body // "")}')
  else
    echo -e "\n=========================================="
    echo "=== Fetching next unblocked issue ==="
    echo "=========================================="
    ISSUE_JSON=$(ralph_next_issue)
  fi

  ISSUE_NUM=$(jq -r '.number // empty' <<< "$ISSUE_JSON")
  if [ -z "$ISSUE_NUM" ]; then
    echo "No more unblocked issues found. Ralph Loop finished!"
    break
  fi
  ISSUE_TITLE=$(jq -r '.title' <<< "$ISSUE_JSON")
  ISSUE_BODY=$(jq -r '.body' <<< "$ISSUE_JSON")

  echo "Processing Issue #$ISSUE_NUM: $ISSUE_TITLE"
  gh api "repos/$RALPH_REPO/issues/$ISSUE_NUM/labels" -f "labels[]=$RALPH_LOCK_LABEL" > /dev/null
  LOCKED_ISSUE=$ISSUE_NUM
  WORKTREE=$("$RALPH_BIN" worktree create "$ISSUE_NUM")
  ISSUE_COST=0

  run_phases "$RALPH_MODEL"
  if [ "$(ralph_issue_state "$ISSUE_NUM")" = open ] && [ -n "$RALPH_ESCALATE_MODEL" ] && [ "$RALPH_MODEL" != "$RALPH_ESCALATE_MODEL" ]; then
    echo -e "\n--- Issue #$ISSUE_NUM still open after all phases on $RALPH_MODEL. One more pass on $RALPH_ESCALATE_MODEL. ---"
    run_phases "$RALPH_ESCALATE_MODEL"
  fi

  ISSUE_STATE=$(ralph_issue_state "$ISSUE_NUM")
  unlock_issue
  echo -e "\n--- Issue #$ISSUE_NUM: total cost \$$(jq -n "$ISSUE_COST * 100 | round / 100") (ledger: $RALPH_COST_LEDGER) ---"

  if [ "$ISSUE_STATE" = closed ]; then
    "$RALPH_BIN" worktree remove "$ISSUE_NUM"
  else
    # Keep the worktree so a human can inspect it.
    PROGRESS_FILE="$WORKTREE/logs/issue-$ISSUE_NUM.progress.md"
    if [ -f "$PROGRESS_FILE" ]; then
      echo -e "\n--- Progress for Issue #$ISSUE_NUM ---"
      cat "$PROGRESS_FILE"
      echo "---"
    fi
    echo "Worktree kept at $WORKTREE."
  fi
  # Stop instead of re-running the same issue forever if the run ended without closing it.
  if [ "$ISSUE_STATE" = open ]; then
    echo "Issue #$ISSUE_NUM is still open after all phases. Stopping so you can check $RALPH_LOGS_DIR/issue-$ISSUE_NUM.*.log."
    exit 1
  fi

  if [ -n "$ONLY_ISSUE" ]; then
    echo -e "\n---> Issue #$ISSUE_NUM $ISSUE_STATE."
    break
  fi

  echo -e "\n---> Issue #$ISSUE_NUM $ISSUE_STATE! Moving to next issue in ${RALPH_PAUSE_SECONDS:-5} seconds...\n"
  sleep "${RALPH_PAUSE_SECONDS:-5}"
done
