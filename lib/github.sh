# shellcheck shell=bash
# GitHub helpers. REST only (`gh api`): cloud sessions block GraphQL (HTTP 403), which every
# `gh issue|pr <subcommand>` uses.

# jq: the issue numbers under an issue's "## Blocked by" heading that are still in $open.
# shellcheck disable=SC2016
RALPH_JQ_OPEN_BLOCKERS='def open_blockers($open):
  [(.body // "") | capture("## Blocked by(?<b>[\\s\\S]*?)(\\n## |\\n---|$)").b // "" |
    scan("#([0-9]+)")[0] | tonumber] | map(select(. as $n | $open | index($n)));'

# All open issues (not PRs), as one JSON array.
ralph_open_issues() {
  gh api --paginate "repos/$RALPH_REPO/issues?state=open&per_page=100" |
    jq -s 'add // [] | map(select(has("pull_request") | not))'
}

# closed | needs-human | blocked | open
ralph_issue_state() {
  gh api "repos/$RALPH_REPO/issues/$1" \
    --jq 'if .state == "closed" then "closed" elif any(.labels[]; .name == "needs-human") then "needs-human" elif any(.labels[]; .name == "blocked") then "blocked" else "open" end'
}

ralph_is_locked() {
  gh api "repos/$RALPH_REPO/issues/$1" --jq "any(.labels[]; .name == \"$RALPH_LOCK_LABEL\")"
}

# The oldest open issue that isn't labeled blocked / needs-human / locked and whose
# "## Blocked by" lists no open issue, as {number, title, body}; `null` if there is none.
ralph_next_issue() {
  ralph_open_issues | jq --arg lock "$RALPH_LOCK_LABEL" "$RALPH_JQ_OPEN_BLOCKERS"'
    map(.number) as $open |
    map(select(
      (any(.labels[]; .name == "blocked" or .name == "needs-human" or .name == $lock) | not) and
      (open_blockers($open) | length == 0)
    )) | sort_by(.number) | .[0] | if . then {number, title, body: (.body // "")} else null end'
}

# Removes `blocked` from every open issue whose "## Blocked by" issues are all closed.
ralph_unblock_dependents() {
  local n
  ralph_open_issues | jq -r "$RALPH_JQ_OPEN_BLOCKERS"'
    map(.number) as $open |
    .[] | select(any(.labels[]; .name == "blocked")) |
    select(open_blockers($open) | length == 0) | .number' |
    while read -r n; do
      echo "Unblocking #$n"
      gh api -X DELETE "repos/$RALPH_REPO/issues/$n/labels/blocked" > /dev/null
    done
}

ralph_ensure_labels() {
  gh label create "$RALPH_LOCK_LABEL" --repo "$RALPH_REPO" --color FBCA04 \
    --description "A ralph run is working on this issue" --force > /dev/null 2>&1 || true
}
