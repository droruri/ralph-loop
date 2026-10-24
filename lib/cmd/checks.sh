#!/usr/bin/env bash
# Local checks for a build, run from the repo root (or worktree) the command is called in.
#
# RALPH_CHECKS_CMD set to a command → runs it (e.g. scripts/ralph-checks.sh for related tests only).
# `auto` → runs the package.json scripts lint, typecheck and test that exist, with the project's
# package manager. Output is capped so it doesn't flood the session's context.

set -uo pipefail
. "$RALPH_LIB/lib/common.sh"
ralph_load_config

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

if [ "$RALPH_CHECKS_CMD" != auto ]; then
  [ -z "$RALPH_CHECKS_CMD" ] && {
    echo "No checks configured (RALPH_CHECKS_CMD is empty)."
    exit 0
  }
  bash -c "$RALPH_CHECKS_CMD" 2>&1 | tail -60
  exit "${PIPESTATUS[0]}"
fi

pm=$(ralph_js_pm "$root")
if [ -z "$pm" ]; then
  echo "No package.json and no RALPH_CHECKS_CMD: nothing to check. Set RALPH_CHECKS_CMD in .ralphrc."
  exit 0
fi

ran=0
for script in lint typecheck test; do
  jq -e --arg s "$script" '.scripts[$s]' package.json > /dev/null 2>&1 || continue
  ran=1
  echo "== $script =="
  $pm run "$script" 2>&1 | tail -40
  [ "${PIPESTATUS[0]}" -eq 0 ] || {
    echo "$script FAILED"
    exit 1
  }
done
[ "$ran" = 1 ] || echo "package.json has no lint, typecheck or test script: nothing checked."
exit 0
