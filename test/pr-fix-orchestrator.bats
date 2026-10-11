#!/usr/bin/env bats
#
# Tests for scripts/pr-fix-orchestrator.sh, run as a subprocess with a fake `gh`.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pr-fix-orchestrator.sh"
  PATH="${BATS_TEST_DIRNAME}/support:${PATH}"
  export PATH
  TEST_TMP="$(mktemp -d)"
  export GH_LOG="$TEST_TMP/gh.log" GH_BODIES="$TEST_TMP/bodies"
  : >"$GH_LOG"
  : >"$GH_BODIES"
  export REPO="o/r" SERVER_URL="https://github.com" AUTHOR="asbjornu" MAX_ROUNDS="6"
  export GH_AW_DISPATCH_TOKEN="dispatch-token"
}

teardown() {
  rm -rf "$TEST_TMP"
}

json() {
  printf '%s' "$2" >"$TEST_TMP/$1.json"
  export "$1=$TEST_TMP/$1.json"
}

dispatch_fixtures() {
  json GH_WORKFLOWS_FILE '{"workflows":[{"id":5,"path":".github/workflows/pr-fix.lock.yml"}]}'
  json GH_RUNS_FILE '{"total_count":0}'
  json GH_PULLS_FILE '[{"number":1,"draft":false,"user":{"login":"asbjornu"},"head":{"repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}]'
  json GH_PULL_FILE '{"head":{"sha":"head1"}}'
  json GH_COMMENTS_FILE '[]'
  json GH_REVIEWS_FILE '[{"id":77,"state":"COMMENTED","commit_id":"head1","submitted_at":"2024-01-01T00:00:00Z","user":{"login":"copilot-pull-request-reviewer[bot]"}}]'
  json GH_POST_COMMENT_FILE '{"id":900}'
  json GH_PATCH_COMMENT_FILE '{}'
  export GH_AW_OUT="View workflow run: https://github.com/o/r/actions/runs/424242"
}

@test "does nothing when the workflow is not on the default branch" {
  json GH_WORKFLOWS_FILE '{"workflows":[]}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  ! grep -q "aw run" "$GH_LOG"
}

@test "skips when a run is already pending" {
  json GH_WORKFLOWS_FILE '{"workflows":[{"id":5,"path":".github/workflows/pr-fix.lock.yml"}]}'
  json GH_RUNS_FILE '{"total_count":1}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already pending"* ]]
  ! grep -q "aw run" "$GH_LOG"
}

@test "dispatches one PR and records the run id on the marker" {
  dispatch_fixtures
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatching fixer for review 77 (round 1)"* ]]
  grep -q "aw run pr-fix" "$GH_LOG"
  grep -q -- "-X PATCH repos/o/r/issues/comments/900" "$GH_LOG"
  grep -q "run=424242" "$GH_BODIES"
  grep -q "<!-- aw-pr-fix-state" "$GH_BODIES"
}
