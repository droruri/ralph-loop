# shellcheck shell=bash
# Builds the instructions a phase session gets.
#
# Each part comes from the project's override, <project>/$RALPH_PROMPTS_DIR/<part>.md, when it
# exists, else from this package's prompts/<part>.md. The project's notes
# ($RALPH_PROMPTS_DIR/project.md) are appended last. {{PLACEHOLDERS}} are filled from the config.

ralph_prompt_file() {
  local part=$1 own="$RALPH_PROJECT/$RALPH_PROMPTS_DIR/$1.md"
  if [ -f "$own" ]; then
    echo "$own"
  elif [ -f "$RALPH_LIB/prompts/$part.md" ]; then
    echo "$RALPH_LIB/prompts/$part.md"
  else
    return 1
  fi
}

ralph_fill_placeholders() {
  local text=$1 key var value
  # Bash 5.2 makes `&` in a replacement mean "the match"; values are taken literally here.
  shopt -u patsub_replacement 2> /dev/null || true
  for key in RALPH REPO BASE_BRANCH BRANCH_PREFIX MERGE_METHOD SPEC_DOC PLAN_SKILL TDD_SKILL \
    REVIEWER_AGENT INVESTIGATOR_AGENT DIFF_EXCLUDE PROMPTS_DIR; do
    var=RALPH_$key
    [ "$key" = RALPH ] && var=RALPH_BIN
    value=${!var}
    text=${text//"{{$key}}"/$value}
  done
  printf '%s\n' "$text"
}

# ralph_compose_prompt <phase>: shared + phase steps (+ review steps for build) + project notes.
# Build also gets the review steps: a small diff is reviewed in the same session.
ralph_compose_prompt() {
  local phase=$1 part file text=""
  local parts=(shared "$phase")
  [ "$phase" = build ] && parts+=(review)
  for part in "${parts[@]}"; do
    file=$(ralph_prompt_file "$part") || ralph_die "no prompt for '$part' (looked in $RALPH_PROMPTS_DIR/ and $RALPH_LIB/prompts/)"
    text+=$(cat "$file")$'\n\n'
  done
  if [ -f "$RALPH_PROJECT/$RALPH_PROMPTS_DIR/project.md" ]; then
    text+=$(cat "$RALPH_PROJECT/$RALPH_PROMPTS_DIR/project.md")$'\n'
  fi
  ralph_fill_placeholders "$text"
}
