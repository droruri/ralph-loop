#!/usr/bin/env bash
# ralph init [--prompts] [--skills]: sets up the current project. Re-runnable: never overwrites a
# file that exists, and skips (with a warning) the GitHub step when gh can't reach the repo.

set -euo pipefail
. "$RALPH_LIB/lib/common.sh"
. "$RALPH_LIB/lib/github.sh"

with_prompts=0
with_skills=0
for arg in "$@"; do
  case "$arg" in
    --prompts) with_prompts=1 ;;
    --skills) with_skills=1 ;;
    *) ralph_die "usage: ralph init [--prompts] [--skills]" ;;
  esac
done

root=$(ralph_project_root) || ralph_die "not inside a git repository"
cd "$root"

# copy_new <src> <dest>: copies unless dest exists.
copy_new() {
  if [ -e "$2" ]; then
    echo "kept     $2 (exists)"
  else
    mkdir -p "$(dirname "$2")"
    cp "$1" "$2"
    echo "created  $2"
  fi
}

copy_new "$RALPH_LIB/templates/ralphrc" .ralphrc
ralph_load_config
copy_new "$RALPH_LIB/templates/project.md" "$RALPH_PROMPTS_DIR/project.md"
if [ "$with_prompts" = 1 ]; then
  for part in shared build review merge; do
    copy_new "$RALPH_LIB/prompts/$part.md" "$RALPH_PROMPTS_DIR/$part.md"
  done
fi
if [ "$with_skills" = 1 ]; then
  for skill in "$RALPH_LIB"/skills/*/; do
    name=$(basename "$skill")
    copy_new "$skill/SKILL.md" ".claude/skills/$name/SKILL.md"
  done
fi

# Worktrees and run logs stay out of git.
touch .gitignore
for entry in .ralph/ logs/; do
  if grep -qxF "$entry" .gitignore; then
    echo "kept     .gitignore entry $entry"
  else
    printf '%s\n' "$entry" >> .gitignore
    echo "added    .gitignore entry $entry"
  fi
done

if command -v gh > /dev/null && gh api "repos/$RALPH_REPO" --jq .full_name > /dev/null 2>&1; then
  ralph_ensure_labels
  for label in "blocked:B60205:Waits on an open issue under ## Blocked by" \
    "needs-human:D93F0B:Needs a person before ralph can go on"; do
    IFS=: read -r name color desc <<< "$label"
    gh label create "$name" --repo "$RALPH_REPO" --color "$color" --description "$desc" --force > /dev/null 2>&1 || true
  done
  echo "labels   $RALPH_LOCK_LABEL, blocked, needs-human on $RALPH_REPO"
else
  ralph_warn "gh can't reach $RALPH_REPO: labels not created (ralph run creates the lock label itself)."
fi

cat << EOF

Next:
  1. Edit .ralphrc and $RALPH_PROMPTS_DIR/project.md for this project.
  2. Write issues with acceptance-criteria checklists; list blockers as #N under "## Blocked by".
  3. ralph next      # which issue would run
     ralph run       # work through them (or: ralph run <issue>)
EOF
