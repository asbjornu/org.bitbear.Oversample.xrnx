#!/usr/bin/env bats
#
# Tests for scripts/seq-editor.sh, the rebase sequence editor, against a real
# git repository. Verifies the fixup! commit is moved directly after its target.

setup() {
  EDITOR="${BATS_TEST_DIRNAME}/../scripts/seq-editor.sh"
  TEST_TMP="$(mktemp -d)"
  REPO_DIR="$TEST_TMP/repo"
  git init -q -b main "$REPO_DIR"
  git -C "$REPO_DIR" config user.name "github-actions[bot]"
  git -C "$REPO_DIR" config user.email "github-actions[bot]@users.noreply.github.com"

  printf 'base\n' >"$REPO_DIR/f"
  git -C "$REPO_DIR" add f
  git -C "$REPO_DIR" commit -q -m "Base"

  printf 'a\n' >>"$REPO_DIR/f"
  git -C "$REPO_DIR" commit -q -am "Add feature"
  FEATURE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

  printf 'b\n' >>"$REPO_DIR/f"
  git -C "$REPO_DIR" commit -q -am "Add test"
  TEST_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

  printf 'c\n' >>"$REPO_DIR/f"
  git -C "$REPO_DIR" commit -q -am "fixup! Add feature" -m "aw-fixup-target=$FEATURE_SHA"
  FIXUP_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "moves the fixup! commit directly after its target" {
  local todo="$TEST_TMP/todo"
  {
    printf 'pick %s Add feature\n' "$FEATURE_SHA"
    printf 'pick %s Add test\n' "$TEST_SHA"
    printf 'pick %s fixup! Add feature\n' "$FIXUP_SHA"
  } >"$todo"

  (cd "$REPO_DIR" && bash "$EDITOR" "$todo")

  local expected
  expected="$(printf 'pick %s Add feature\nfixup %s\npick %s Add test\n' "$FEATURE_SHA" "$FIXUP_SHA" "$TEST_SHA")"
  [ "$(cat "$todo")" = "$expected" ]
}
