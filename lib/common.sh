# shellcheck shell=bash
# Sourced by every command: project root, configuration and its defaults.

ralph_die() {
  echo "ralph: $*" >&2
  exit 1
}

ralph_warn() {
  echo "ralph: warning: $*" >&2
}

ralph_require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" > /dev/null || ralph_die "'$tool' is required but not on PATH"
  done
}

ralph_issue_arg() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || ralph_die "expected an issue number, got '${1:-}'"
}

# The main checkout, also when run from inside one of ralph's worktrees.
ralph_project_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2> /dev/null) || return 1
  dirname "$common"
}

# owner/repo from the origin remote: https, ssh and proxied URLs all end in /<owner>/<repo>(.git).
ralph_repo_from_remote() {
  git -C "$1" remote get-url origin 2> /dev/null | sed -E 's#\.git$##; s#/+$##; s#.*[:/]([^/:]+)/([^/]+)$#\1/\2#'
}

# Loads <project>/.ralphrc (KEY=value lines), then fills defaults. A RALPH_* variable already set in
# the environment wins over the file, so `RALPH_MODEL=opus ralph run` works.
ralph_load_config() {
  RALPH_PROJECT=$(ralph_project_root) || ralph_die "not inside a git repository"
  local overrides
  overrides=$(export -p | grep -E '^declare -x RALPH_[A-Z0-9_]+=' || true)
  if [ -f "$RALPH_PROJECT/.ralphrc" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$RALPH_PROJECT/.ralphrc"
    set +a
  fi
  # `declare` inside a function would make them local: restore them as globals.
  eval "${overrides//declare -x /declare -gx }"

  : "${RALPH_REPO:=$(ralph_repo_from_remote "$RALPH_PROJECT")}"
  [[ "$RALPH_REPO" =~ ^[^/]+/[^/]+$ ]] || ralph_die "can't tell the GitHub repo from origin; set RALPH_REPO=owner/repo in .ralphrc"
  : "${RALPH_BASE_BRANCH:=main}"
  : "${RALPH_BRANCH_PREFIX:=feature/issue-}"
  : "${RALPH_MERGE_METHOD:=squash}"
  : "${RALPH_LOCK_LABEL:=ralph:running}"
  # Build runs on RALPH_MODEL; an issue still open after all phases gets one more pass on
  # RALPH_ESCALATE_MODEL (empty: no extra pass). Review and merge always use RALPH_CHEAP_MODEL.
  : "${RALPH_MODEL:=sonnet}"
  : "${RALPH_CHEAP_MODEL:=haiku}"
  RALPH_ESCALATE_MODEL="${RALPH_ESCALATE_MODEL-opus}"
  : "${RALPH_TOOLS:=Bash,Read,Edit,Write,Skill,Agent}"
  # Comma-separated plugin ids enabled in the phase sessions, e.g. caveman@caveman.
  RALPH_PLUGINS="${RALPH_PLUGINS-}"
  : "${RALPH_PROMPTS_DIR:=ralph}"
  : "${RALPH_LOGS_DIR:=$RALPH_PROJECT/logs}"
  # `none` turns each of these off; the prompts fall back to doing the job inline.
  : "${RALPH_SPEC_DOC:=none}"
  : "${RALPH_PLAN_SKILL:=none}"
  : "${RALPH_TDD_SKILL:=none}"
  : "${RALPH_REVIEWER_AGENT:=general-purpose}"
  : "${RALPH_INVESTIGATOR_AGENT:=general-purpose}"
  # `auto` detects from the lockfile / package.json; an empty value skips the step.
  RALPH_INSTALL_CMD="${RALPH_INSTALL_CMD-auto}"
  RALPH_CHECKS_CMD="${RALPH_CHECKS_CMD-auto}"
  # Space-separated files linked from the main checkout into each worktree.
  RALPH_LINK_FILES="${RALPH_LINK_FILES-.env}"
  # Pathspecs left out of every review diff, as shell words pasted after `git diff … -- .`.
  # It is only pasted into prompt text, never expanded as words here.
  if [ -z "${RALPH_DIFF_EXCLUDE+set}" ]; then
    # shellcheck disable=SC2089
    RALPH_DIFF_EXCLUDE="':!*-lock.yaml' ':!*-lock.json' ':!*.lock'"
  fi

  # shellcheck disable=SC2090
  export RALPH_PROJECT RALPH_REPO RALPH_BASE_BRANCH RALPH_BRANCH_PREFIX RALPH_MERGE_METHOD \
    RALPH_LOCK_LABEL RALPH_MODEL RALPH_CHEAP_MODEL RALPH_ESCALATE_MODEL RALPH_TOOLS RALPH_PLUGINS \
    RALPH_PROMPTS_DIR RALPH_LOGS_DIR RALPH_SPEC_DOC RALPH_PLAN_SKILL RALPH_TDD_SKILL \
    RALPH_REVIEWER_AGENT RALPH_INVESTIGATOR_AGENT RALPH_INSTALL_CMD RALPH_CHECKS_CMD \
    RALPH_LINK_FILES RALPH_DIFF_EXCLUDE
}

ralph_branch() {
  echo "$RALPH_BRANCH_PREFIX$1"
}

ralph_worktree_path() {
  echo "$RALPH_PROJECT/.ralph/wt/issue-$1"
}

# The package manager a JS project uses, from its lockfile (empty if it isn't one).
ralph_js_pm() {
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    command -v pnpm > /dev/null && echo pnpm || echo "npx pnpm"
  elif [ -f "$dir/yarn.lock" ]; then
    echo yarn
  elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
    echo bun
  elif [ -f "$dir/package.json" ]; then
    echo npm
  fi
}
