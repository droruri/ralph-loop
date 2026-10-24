#!/usr/bin/env bash
# Installs (or updates) ralph for the current user, for projects that don't use npm:
#
#   curl -fsSL https://raw.githubusercontent.com/droruri/ralph-loop/main/install.sh | bash
#
# Clones to RALPH_INSTALL_DIR (~/.ralph-loop) and links bin/ralph into RALPH_BIN_DIR (~/.local/bin).
# RALPH_REF picks a tag or branch (default main).

set -euo pipefail

repo_url=${RALPH_REPO_URL:-https://github.com/droruri/ralph-loop.git}
install_dir=${RALPH_INSTALL_DIR:-$HOME/.ralph-loop}
bin_dir=${RALPH_BIN_DIR:-$HOME/.local/bin}
ref=${RALPH_REF:-main}

for tool in git jq; do
  command -v "$tool" > /dev/null || {
    echo "install: '$tool' is required" >&2
    exit 1
  }
done

if [ -d "$install_dir/.git" ]; then
  git -C "$install_dir" fetch --quiet --tags origin
else
  git clone --quiet "$repo_url" "$install_dir"
fi
git -C "$install_dir" checkout --quiet "$ref"
git -C "$install_dir" pull --quiet --ff-only origin "$ref" 2> /dev/null || true

mkdir -p "$bin_dir"
ln -sf "$install_dir/bin/ralph" "$bin_dir/ralph"
echo "ralph $(jq -r .version "$install_dir/package.json") installed: $bin_dir/ralph"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Add $bin_dir to your PATH." ;;
esac
echo "Then, in a project: ralph init"
