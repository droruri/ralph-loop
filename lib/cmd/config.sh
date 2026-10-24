#!/usr/bin/env bash
# ralph config: prints the resolved configuration (.ralphrc + environment + defaults).

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
ralph_load_config

echo "# ralph $(jq -r .version "$RALPH_LIB/package.json") at $RALPH_LIB"
for var in $(compgen -v RALPH_ | sort); do
  case "$var" in RALPH_LIB | RALPH_BIN) continue ;; esac
  printf '%s=%q\n' "$var" "${!var}"
done
