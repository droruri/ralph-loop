#!/usr/bin/env bash
# ralph next: prints the number of the issue `ralph run` would take next (nothing if none).

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
. "$RALPH_LIB/lib/github.sh"
ralph_load_config

ralph_next_issue | jq -r '.number // empty'
