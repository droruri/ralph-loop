#!/usr/bin/env bash
# The deterministic part of the merge phase (steps 10 and 11 of the prompts): wait for CI on the
# issue's PR, merge it when green, close the issue, unblock dependents.
#
#   ralph merge <issue>
#
# Exit 0: merged (or nothing to merge and the issue is closed). Exit 1: needs the LLM merge phase
# (no open PR, CI red, or the merge failed).
#
# RALPH_CI_POLL_SECONDS (10) and RALPH_CI_POLLS (360, about an hour) bound the wait.

set -uo pipefail
. "$RALPH_LIB/lib/common.sh"
. "$RALPH_LIB/lib/github.sh"
ralph_load_config

ralph_issue_arg "${1:-}"
issue=$1
branch=$(ralph_branch "$issue")
poll_seconds=${RALPH_CI_POLL_SECONDS:-10}
polls=${RALPH_CI_POLLS:-360}

owner="${RALPH_REPO%%/*}"
pr_info=$(gh api "repos/$RALPH_REPO/pulls?head=$owner:$branch&state=open" --jq '.[0] | select(.) | "\(.number) \(.head.sha)"') || {
  echo "GitHub API lookup of the PR for $branch failed."
  exit 1
}
read -r pr sha <<< "$pr_info"
if [ -z "${pr:-}" ]; then
  echo "No open PR for $branch."
  exit 1
fi

# check_state: prints none (no runs yet), pending, red or green for the PR head commit.
# Reads check runs and legacy commit statuses; an API failure prints "error", which the wait loop retries.
check_state() {
  local runs status
  runs=$(gh api --paginate "repos/$RALPH_REPO/commits/$sha/check-runs?per_page=100" | jq -rs '
    [.[].check_runs[]] as $r |
    if ($r | length) == 0 then "none"
    elif any($r[]; .status != "completed") then "pending"
    elif any($r[]; .conclusion | IN("success", "neutral", "skipped") | not) then "red"
    else "green" end') || {
    echo error
    return
  }
  status=$(gh api "repos/$RALPH_REPO/commits/$sha/status" --jq '
    if .total_count == 0 then "none" elif .state == "success" then "green" else .state end') || {
    echo error
    return
  }
  case "$status" in
    failure | error)
      echo red
      return
      ;;
    pending)
      if [ "$runs" = green ] || [ "$runs" = none ]; then
        echo pending
        return
      fi
      ;;
    green) [ "$runs" = none ] && runs=green ;;
  esac
  echo "$runs"
}

# Checks can take a moment to register after the last push; CI itself can take a while.
echo "Waiting for CI on PR #$pr..."
state=none
for i in $(seq 1 "$polls"); do
  state=$(check_state)
  case "$state" in
    green | red) break ;;
    none) [ "$i" -gt 12 ] && break ;;
  esac
  sleep "$poll_seconds"
done
if [ "$state" != green ]; then
  echo "CI is not green on PR #$pr ($state)."
  exit 1
fi

# The branch is checked out in the issue's worktree, so it is not deleted via the API.
# `ralph worktree remove` deletes the local branch; the remote one is deleted here.
if ! gh api -X PUT "repos/$RALPH_REPO/pulls/$pr/merge" -f merge_method="$RALPH_MERGE_METHOD" > /dev/null; then
  echo "Merge of PR #$pr failed."
  exit 1
fi
git -C "$RALPH_PROJECT" push origin --delete "$branch" > /dev/null 2>&1 || true

# "Closes #N" normally closes the issue; close it explicitly if the PR body lacked it.
if [ "$(gh api "repos/$RALPH_REPO/issues/$issue" --jq .state)" != closed ]; then
  gh api "repos/$RALPH_REPO/issues/$issue/comments" -f body="Merged in #$pr." > /dev/null
  gh api -X PATCH "repos/$RALPH_REPO/issues/$issue" -f state=closed > /dev/null
fi
ralph_unblock_dependents
echo "PR #$pr merged; issue #$issue closed."
