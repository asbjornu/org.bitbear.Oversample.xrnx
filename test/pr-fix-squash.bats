#!/usr/bin/env bats
#
# End-to-end test for scripts/pr-fix-squash.sh against a real git repository:
# real commits, a real `git rebase -i` driven by scripts/seq-editor.sh, and a
# real force-push to a local bare remote. The gh client is faked.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pr-fix-squash.sh"
  PATH="${BATS_TEST_DIRNAME}/support:${PATH}"
  export PATH
  TEST_TMP="$(mktemp -d)"
  export GH_LOG="$TEST_TMP/gh.log" GH_BODIES="$TEST_TMP/bodies"
  : >"$GH_LOG"
  : >"$GH_BODIES"
  export REPO="o/r" PR="1" BASE_REF="main" HEAD_REF="fix/pr"
  export GH_USER_FILE="$TEST_TMP/user.json"
  printf '%s' '{"login":"maintainer"}' >"$GH_USER_FILE"

  REMOTE="$TEST_TMP/remote.git"
  REPO_DIR="$TEST_TMP/repo"
  git init --bare -q -b main "$REMOTE"
  git init -q -b main "$REPO_DIR"
  git -C "$REPO_DIR" config user.name "github-actions[bot]"
  git -C "$REPO_DIR" config user.email "github-actions[bot]@users.noreply.github.com"
  printf 'base\n' >"$REPO_DIR/file.txt"
  git -C "$REPO_DIR" add file.txt
  git -C "$REPO_DIR" commit -q -m "Base commit"
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" remote add origin "$REMOTE"
  git -C "$REPO_DIR" push -q -u origin main

  git -C "$REPO_DIR" checkout -q -b fix/pr
  printf 'feature\n' >>"$REPO_DIR/file.txt"
  git -C "$REPO_DIR" commit -q -am "Add feature"
  local feature_sha
  feature_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  printf 'more\n' >>"$REPO_DIR/file.txt"
  git -C "$REPO_DIR" commit -q -am "fixup! Add feature" -m "aw-fixup-target=$feature_sha"
  git -C "$REPO_DIR" push -q -u origin fix/pr

  export GH_COMMENTS_FILE="$TEST_TMP/comments.json"
  printf '[{"body":"<!-- aw-pr-fix-state review=77 pr=1 round=1 run=111 head=%s -->","id":900,"created_at":"2024-01-01T00:00:00Z","user":{"login":"maintainer"}}]' \
    "$BASE_SHA" >"$GH_COMMENTS_FILE"
  export GH_COMPARE_FILE="$TEST_TMP/compare.json"
  printf '%s' '{"total_commits":2,"commits":[{"author":{"login":"github-actions[bot]"},"commit":{"message":"Add feature"}},{"author":{"login":"github-actions[bot]"},"commit":{"message":"fixup! Add feature"}}]}' \
    >"$GH_COMPARE_FILE"
  export GH_POST_COMMENT_FILE="$TEST_TMP/post.json"
  printf '%s' '{"id":4242}' >"$GH_POST_COMMENT_FILE"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "folds the fixup and force-pushes to the remote" {
  cd "$REPO_DIR" || return 1
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  local subjects
  subjects="$(git -C "$REPO_DIR" log --format=%s)"
  [[ "$subjects" == *"Add feature"* ]]
  [[ "$subjects" != *"fixup!"* ]]
  [ "$(printf '%s\n' "$subjects" | wc -l | tr -d ' ')" = "2" ]

  local local_head remote_head
  local_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  remote_head="$(git -C "$REPO_DIR" ls-remote origin refs/heads/fix/pr | cut -f1)"
  [ "$local_head" = "$remote_head" ]
  grep -q "aw-pr-fix-squash-anchor" "$GH_BODIES"
}
