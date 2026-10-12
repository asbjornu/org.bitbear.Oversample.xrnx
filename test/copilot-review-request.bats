#!/usr/bin/env bats
#
# Tests for scripts/copilot-review-request.sh. The script runs as a subprocess
# with a fake `gh` (test/support/gh) on PATH and canned JSON responses.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/copilot-review-request.sh"
  PATH="${BATS_TEST_DIRNAME}/support:${PATH}"
  export PATH
  TEST_TMP="$(mktemp -d)"
  export GH_LOG="$TEST_TMP/gh.log" GH_BODIES="$TEST_TMP/bodies"
  : >"$GH_LOG"
  : >"$GH_BODIES"
  export REPO="o/r" PR="1" AUTHOR="asbjornu"
  json GH_PULL_FILE '{"state":"open","draft":false,"user":{"login":"asbjornu"},"head":{"repo":{"full_name":"o/r"},"sha":"head123"}}'
}

teardown() {
  rm -rf "$TEST_TMP"
}

json() {
  printf '%s' "$2" >"$TEST_TMP/$1.json"
  export "$1=$TEST_TMP/$1.json"
}

@test "draft PR is skipped" {
  json GH_PULL_FILE '{"state":"open","draft":true,"user":{"login":"asbjornu"},"head":{"repo":{"full_name":"o/r"},"sha":"head123"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is a draft"* ]]
  ! grep -q requested_reviewers "$GH_LOG"
}

@test "foreign author is skipped" {
  json GH_PULL_FILE '{"state":"open","draft":false,"user":{"login":"someone"},"head":{"repo":{"full_name":"o/r"},"sha":"head123"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not asbjornu"* ]]
  ! grep -q requested_reviewers "$GH_LOG"
}

@test "fork PR is skipped" {
  json GH_PULL_FILE '{"state":"open","draft":false,"user":{"login":"asbjornu"},"head":{"repo":{"full_name":"x/y"},"sha":"head123"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fork"* ]]
  ! grep -q requested_reviewers "$GH_LOG"
}

@test "requests a review when the head is unreviewed" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Requested a Copilot review"* ]]
  grep -q "requested_reviewers" "$GH_LOG"
}

@test "skips when the head already has a Copilot review" {
  json GH_REVIEWS_FILE '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"commit_id":"head123"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already has a Copilot review"* ]]
  ! grep -q requested_reviewers "$GH_LOG"
}

@test "quietly skips a fixer-only head under an active dispatch" {
  json GH_COMMITS_FILE '[{"commit":{"message":"fixup! Add thing"},"author":{"login":"github-actions[bot]"}}]'
  json GH_COMMENTS_FILE '[{"body":"<!-- aw-pr-fix-state review=1 pr=1 round=1 run=9 head=base00 -->","id":1,"created_at":"2024-01-01T00:00:00Z","user":{"login":"maintainer"}}]'
  json GH_COMPARE_FILE '{"status":"ahead","total_commits":1,"commits":[{"author":{"login":"github-actions[bot]"}}]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"squash workflow will re-request"* ]]
  ! grep -q requested_reviewers "$GH_LOG"
}
