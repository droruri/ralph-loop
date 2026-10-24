#!/usr/bin/env bash
# One git worktree per issue, so a run never switches branches in the main checkout.
#
#   ralph worktree create <issue>   prints the worktree path (reuses an existing one)
#   ralph worktree remove <issue>   removes the worktree and the local branch
#
# The worktree lives at <main checkout>/.ralph/wt/issue-<issue> on branch <prefix><issue>: the
# existing local or remote branch if there is one, else a new branch from origin/<base>.

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
ralph_load_config

cmd="${1:-}"
[[ "$cmd" =~ ^(create|remove)$ ]] || ralph_die "usage: ralph worktree create|remove <issue>"
ralph_issue_arg "${2:-}"
issue=$2
root=$RALPH_PROJECT
wt=$(ralph_worktree_path "$issue")
branch=$(ralph_branch "$issue")

install_deps() {
  local install=$RALPH_INSTALL_CMD pm
  if [ "$install" = auto ]; then
    pm=$(ralph_js_pm "$wt")
    case "$pm" in
      "") install="" ;;
      npm) install="npm ci" ;;
      yarn) install="yarn install --frozen-lockfile" ;;
      bun) install="bun install --frozen-lockfile" ;;
      *) install="$pm install --frozen-lockfile" ;;
    esac
  fi
  [ -z "$install" ] && return 0
  (cd "$wt" && bash -c "$install" 2>&1 | tail -3)
}

case "$cmd" in
  create)
    git -C "$root" fetch origin --quiet --prune
    if [ ! -d "$wt" ]; then
      git -C "$root" worktree prune
      # Progress goes to stderr: stdout is only the path.
      if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$root" worktree add --quiet "$wt" "$branch" >&2
      elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git -C "$root" worktree add --quiet --track -b "$branch" "$wt" "origin/$branch" >&2
      else
        git -C "$root" worktree add --quiet --no-track -b "$branch" "$wt" "origin/$RALPH_BASE_BRANCH" >&2
      fi
      for f in $RALPH_LINK_FILES; do
        [ -e "$root/$f" ] && ln -sf "$root/$f" "$wt/$f"
      done
      install_deps >&2
    fi
    echo "$wt"
    ;;
  remove)
    if [ -d "$wt" ]; then
      git -C "$root" worktree remove --force "$wt"
    fi
    git -C "$root" worktree prune
    git -C "$root" branch -D "$branch" > /dev/null 2>&1 || true
    ;;
esac
