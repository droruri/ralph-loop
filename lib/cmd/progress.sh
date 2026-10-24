#!/usr/bin/env bash
# Syncs a progress file with one GitHub issue comment, so a run on any machine (local or cloud)
# can resume from it. The comment starts with a marker and is edited in place.
#
#   ralph progress pull <issue>   comment → logs/issue-<issue>.progress.md (cwd)
#   ralph progress push <issue>   logs/issue-<issue>.progress.md (cwd) → comment
#
# `pull` with no comment leaves no file. `push` with no file does nothing.

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
ralph_load_config

MARKER='<!-- ralph-progress -->'
cmd="${1:-}"
[[ "$cmd" =~ ^(pull|push)$ ]] || ralph_die "usage: ralph progress pull|push <issue>"
ralph_issue_arg "${2:-}"
issue=$2
file="logs/issue-$issue.progress.md"

comment_id() {
  gh api --paginate "repos/$RALPH_REPO/issues/$issue/comments" \
    --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -1
}

case "$cmd" in
  pull)
    id=$(comment_id)
    [ -z "$id" ] && exit 0
    mkdir -p logs
    # Drop the marker, the opening fence and the closing fence.
    gh api "repos/$RALPH_REPO/issues/comments/$id" --jq .body | sed '1,2d;$d' > "$file"
    ;;
  push)
    [ -f "$file" ] || exit 0
    body=$(mktemp)
    trap 'rm -f "$body"' EXIT
    {
      echo "$MARKER"
      echo '```text'
      cat "$file"
      echo '```'
    } > "$body"
    id=$(comment_id)
    if [ -n "$id" ]; then
      gh api -X PATCH "repos/$RALPH_REPO/issues/comments/$id" -F "body=@$body" > /dev/null
    else
      gh api "repos/$RALPH_REPO/issues/$issue/comments" -F "body=@$body" > /dev/null
    fi
    ;;
esac
