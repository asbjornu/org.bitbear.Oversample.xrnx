#!/usr/bin/env bats
#
# Unit tests for scripts/sensitive-file-warning.sh.
#
# Pure helpers are tested directly; main() is tested end-to-end against a fake
# `gh` on GH_BIN that logs its invocations ($GH_LOG) and captures the JSON body
# of POST/PATCH requests ($GH_BODY_FILE).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sensitive-file-warning.sh"
  # shellcheck source=/dev/null
  source "$SCRIPT"

  TEST_TMP="$(mktemp -d)"
  BIN="$TEST_TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
args=("$@")
method="GET"
endpoint=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -X) method="${args[$((i + 1))]}" ;;
    repos/*) endpoint="${args[$i]}" ;;
  esac
done
if [[ "$method" == "GET" && "$endpoint" == *"/files"* ]]; then
  cat "$GH_FILES"
elif [[ "$method" == "GET" && "$endpoint" == *"/comments"* ]]; then
  [[ -n "${GH_COMMENT_ID:-}" ]] && printf '%s\n' "$GH_COMMENT_ID"
elif [[ "$method" == "POST" || "$method" == "PATCH" ]]; then
  cat > "$GH_BODY_FILE"
  printf '%s ok\n' "$method"
elif [[ "$method" == "DELETE" ]]; then
  printf 'DELETE ok\n'
fi
GHEOF
  chmod +x "$BIN/gh"

  export GH_BIN="$BIN/gh"
  export GH_LOG="$TEST_TMP/gh.log"
  export GH_BODY_FILE="$TEST_TMP/body.json"
  export GH_FILES="$TEST_TMP/files.txt"
  export REPO="o/r"
  export PR="1"
  : > "$GH_LOG"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "matching is anchored, not a substring" {
  local patterns; patterns="$(mktemp)"
  sensitive_patterns > "$patterns"
  run select_sensitive_files "$patterns" <<< "docs/my.github/x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "matching selects sensitive paths and preserves order" {
  local patterns; patterns="$(mktemp)"
  sensitive_patterns > "$patterns"
  run select_sensitive_files "$patterns" <<< $'src/a.lua\nAGENTS.md\n.github/workflows/x.yml\nREADME.md'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "AGENTS.md" ]
  [ "${lines[1]}" = ".github/workflows/x.yml" ]
  [ "${lines[2]}" = "README.md" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "comment body has marker, warning callout and bullet list" {
  run build_comment_body <<< $'AGENTS.md\nREADME.md'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!-- sensitive-file-warning -->"* ]]
  [[ "$output" == *"> [!WARNING]"* ]]
  [[ "$output" == *'- `AGENTS.md`'* ]]
  [[ "$output" == *'- `README.md`'* ]]
  [[ "$output" == *"before merge"* ]]
}

@test "no hits, no comment: does not write" {
  printf '%s\n' "src/a.lua" > "$GH_FILES"
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"No sensitive files touched."* ]]
  ! grep -q -- "-X POST" "$GH_LOG"
  ! grep -q -- "-X DELETE" "$GH_LOG"
}

@test "no hits, existing comment: deletes it" {
  printf '%s\n' "src/a.lua" > "$GH_FILES"
  export GH_COMMENT_ID="555"
  run main
  [ "$status" -eq 0 ]
  grep -q -- "-X DELETE repos/o/r/issues/comments/555" "$GH_LOG"
}

@test "hits, no comment: posts a new sticky comment with the body" {
  printf '%s\n' "src/a.lua" ".github/workflows/x.yml" > "$GH_FILES"
  run main
  [ "$status" -eq 0 ]
  grep -q -- "-X POST repos/o/r/issues/1/comments" "$GH_LOG"
  grep -q "sensitive-file-warning" "$GH_BODY_FILE"
  grep -q ".github/workflows/x.yml" "$GH_BODY_FILE"
}

@test "hits, existing comment: patches it instead of posting" {
  printf '%s\n' "AGENTS.md" > "$GH_FILES"
  export GH_COMMENT_ID="777"
  run main
  [ "$status" -eq 0 ]
  grep -q -- "-X PATCH repos/o/r/issues/comments/777" "$GH_LOG"
  ! grep -q -- "-X POST" "$GH_LOG"
  grep -q "AGENTS.md" "$GH_BODY_FILE"
}
