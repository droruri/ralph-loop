#!/usr/bin/env bash
# ralph prompt <phase> [issue]: prints the instructions a phase session gets. With an issue
# number, prints the full prompt `ralph run` sends (fetches the issue; needs gh).

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
. "$RALPH_LIB/lib/prompt.sh"
ralph_load_config

phase="${1:-}"
[[ "$phase" =~ ^(build|review|merge)$ ]] || ralph_die "usage: ralph prompt build|review|merge [issue]"
if [ -z "${2:-}" ]; then
  ralph_compose_prompt "$phase"
  exit 0
fi
ralph_issue_arg "$2"
. "$RALPH_LIB/lib/session.sh"
json=$(gh api "repos/$RALPH_REPO/issues/$2" --jq '{title, body: (.body // "")}')
ralph_session_prompt "$phase" "$2" "$(ralph_worktree_path "$2")" \
  "$(jq -r .title <<< "$json")" "$(jq -r .body <<< "$json")"
