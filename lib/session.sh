# shellcheck shell=bash
# One phase session: the prompt it gets and the `claude` process that runs it.
. "$RALPH_LIB/lib/prompt.sh"

# ralph_session_prompt <phase> <issue> <worktree> <title> <body>
ralph_session_prompt() {
  local phase=$1 issue=$2 wt=$3 title=$4 body=$5
  cat << EOF
Execute PHASE $phase of the ralph instructions below for Issue #$issue.

$(ralph_compose_prompt "$phase")

Your working directory is this issue's worktree, $wt, already on branch $(ralph_branch "$issue"). Work only inside it.

ISSUE TITLE: $title

ISSUE DETAILS & CHECKLIST:
$body
EOF
}

# Settings for every phase session: hooks off and only the plugins in RALPH_PLUGINS enabled.
# RALPH_CLAUDE_SETTINGS (a JSON string) replaces this entirely.
ralph_claude_settings() {
  if [ -n "${RALPH_CLAUDE_SETTINGS:-}" ]; then
    printf '%s\n' "$RALPH_CLAUDE_SETTINGS"
    return
  fi
  jq -cn --arg p "$RALPH_PLUGINS" \
    '{disableAllHooks: true, enabledPlugins: ($p | split(",") | map(gsub("^\\s+|\\s+$"; "")) |
      map(select(length > 0) | {(.): true}) | add // {})}'
}

# ralph_run_claude <phase> <model> <issue> <worktree> <title> <body>
# Sets RESETS_AT (epoch seconds a usage limit resets, 0 if none) and adds to ISSUE_COST.
ralph_run_claude() {
  local phase=$1 model=$2 issue=$3 wt=$4 title=$5 body=$6
  local log_file="$RALPH_LOGS_DIR/issue-$issue.$phase.log" prompt settings
  prompt=$(ralph_session_prompt "$phase" "$issue" "$wt" "$title" "$body")
  settings=$(ralph_claude_settings)
  echo -e "\n--- Issue #$issue: phase $phase on $model (log: $log_file) ---"

  # stream-json emits one event per line: the raw events go to the log file, and a readable
  # summary (text + tool calls) is printed. `fromjson?` skips non-JSON lines (stderr).
  # The fixed context (tool, skill and agent definitions, plugin hooks) is re-sent every turn, so
  # load only what the prompts use: --tools, an empty MCP config, and --setting-sources project
  # with --settings enabling just RALPH_PLUGINS.
  (cd "$wt" && CLAUDE_CODE_DISABLE_BUNDLED_SKILLS=1 CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1 \
    "${RALPH_CLAUDE:-claude}" --model "$model" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --tools "$RALPH_TOOLS" --setting-sources project --settings "$settings" \
    --dangerously-skip-permissions --verbose --print --output-format stream-json "$prompt" 2>&1) |
    tee "$log_file" | jq --unbuffered -rR '
      fromjson? | select(.type == "assistant") | .message.content[]? |
      if .type == "text" then .text
      elif .type == "tool_use" then "  → \(.name) \(.input | tostring | .[0:150])"
      else empty end' || true

  # A log can hold several sessions (the agent stops and is re-invoked after background work):
  # turns and time sum over all of them; cost is the final cumulative value.
  local result
  result=$(jq -sR '[split("\n")[] | fromjson? | select(type == "object" and .type == "result")] |
    select(length > 0) | {turns: (map(.num_turns // 0) | add), cost: (last.total_cost_usd // 0),
     seconds: ((map(.duration_ms // 0) | add) / 1000 | floor), error: last.is_error}' "$log_file")
  if [ -n "$result" ]; then
    printf '%s\n' "$result" | jq -r --arg d "$(date -u +%FT%TZ)" --arg i "$issue" --arg p "$phase" --arg m "$model" \
      '[$d, $i, $p, $m, .turns, .cost, .seconds, .error] | @tsv' >> "$RALPH_COST_LEDGER"
    ISSUE_COST=$(jq -n "$ISSUE_COST + $(printf '%s\n' "$result" | jq '.cost')")
    printf '%s\n' "$result" | jq -r '"--- phase done: \(.turns) turns, $\(.cost * 100 | round / 100), \(.seconds)s ---"'
  fi

  # A subscription usage limit ends the run early: note when it resets.
  RESETS_AT=$(jq -rR 'fromjson? | select(.type == "rate_limit_event" and .rate_limit_info.status == "rejected") |
    .rate_limit_info.resetsAt // 0' "$log_file" | tail -1)
  RESETS_AT=${RESETS_AT:-0}
}
