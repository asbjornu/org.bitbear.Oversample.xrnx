#!/usr/bin/env bash
#
# Dispatches the gh-aw PR Fixer for new Copilot reviews, one PR per cycle, and
# surfaces terminal fixer failures as PR comments. See pr-fix-orchestrator.yml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ci.sh"

readonly LOCK_PATH=".github/workflows/pr-fix.lock.yml"

is_failure_conclusion() {
  case "$1" in
    failure | cancelled | timed_out | startup_failure | stale | missing) return 0 ;;
    *) return 1 ;;
  esac
}

fixer_pending() {
  local repo="$1" wf_id="$2" in_progress queued
  in_progress="$(gh_get "repos/$repo/actions/workflows/$wf_id/runs?status=in_progress&per_page=1" | jq -r '.total_count')"
  queued="$(gh_get "repos/$repo/actions/workflows/$wf_id/runs?status=queued&per_page=1" | jq -r '.total_count')"
  [ "${in_progress:-0}" != "0" ] || [ "${queued:-0}" != "0" ]
}

# Prints the run conclusion, "missing" for a deleted run, or returns 1 on a
# transient read error (the caller retries next cycle).
read_conclusion() {
  local repo="$1" run_id="$2" out
  if out="$(gh api "repos/$repo/actions/runs/$run_id" 2>&1)"; then
    jq -r '.conclusion // "none"' <<<"$out"
    return 0
  fi
  if [[ "$out" == *"HTTP 404"* ]]; then
    echo "missing"
    return 0
  fi
  return 1
}

# Posts a failure summary for a run, once (deduplicated by run id). Returns
# non-zero if the report could not be read or written.
report_failure() {
  local repo="$1" server_url="$2" pr="$3" run_id="$4" conclusion="$5" token_user="$6"
  local marker already
  marker="$(aw_failure_marker "$run_id")"
  if ! already="$(gh_all "repos/$repo/issues/$pr/comments?per_page=100" \
    | jq -r --arg m "$marker" --arg who "$token_user" \
      '[.[] | select((.body | contains($m)) and (.user.login == $who))] | length')"; then
    return 1
  fi
  [ "$already" = "0" ] || return 0

  local failed_jobs="" jobs
  if [ "$conclusion" != "missing" ]; then
    if ! jobs="$(gh_get "repos/$repo/actions/runs/$run_id/jobs?per_page=100")"; then
      return 1
    fi
    failed_jobs="$(jq -r \
      '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | "- **\(.name)** (\(.conclusion))"] | join("\n")' \
      <<<"$jobs")"
  fi

  local run_url="$server_url/$repo/actions/runs/$run_id"
  local body="🤖 PR Fixer run failed (\`$conclusion\`) — [view logs]($run_url)."
  if [ -n "$failed_jobs" ]; then
    body="$body

Failed jobs:
$failed_jobs"
  fi
  body="$body

The orchestrator re-dispatches this review for another round while the configured round limit allows; once no rounds remain, a human needs to investigate.

$marker"

  if ! printf '%s' "$body" | body_json | gh api -X POST "repos/$repo/issues/$pr/comments" --input - >/dev/null; then
    return 1
  fi
  return 0
}

# The latest Copilot review on the head in the COMMENTED state, or "".
copilot_review_on() {
  local repo="$1" pr="$2" head="$3"
  gh_all "repos/$repo/pulls/$pr/reviews?per_page=100" \
    | jq -r --arg head "$head" --arg cp "$COPILOT_LOGINS" '
        ($cp | split(",")) as $cops
        | [.[] | select((.user.login as $l | $cops | index($l)) and (.commit_id == $head))]
        | (sort_by(.submitted_at) | last) as $last
        | if $last and ($last.state | ascii_upcase) == "COMMENTED" then ($last.id | tostring) else "" end'
}

# Writes the pending marker, echoing the comment id.
write_pending() {
  local repo="$1" server_url="$2" pr="$3" token_user="$4" review="$5" round="$6" head="$7" prev_comment="$8"
  local review_url="$server_url/$repo/pull/$pr#pullrequestreview-$review"
  local marker body
  marker="$(aw_state_marker "$review" "$pr" "$round" "none" "$head")"
  body="🤖 PR Fixer is working on Copilot review [\`$review\`]($review_url) (round $round, fixes by [@$token_user]($server_url/$token_user)) — dispatching a run for head \`${head:0:7}\`… $marker"
  if [ -n "$prev_comment" ]; then
    printf '%s' "$body" | body_json | gh api -X PATCH "repos/$repo/issues/comments/$prev_comment" --input - >/dev/null
    printf '%s' "$prev_comment"
  else
    printf '%s' "$body" | body_json | gh api -X POST "repos/$repo/issues/$pr/comments" --input - | jq -r '.id'
  fi
}

# Records the dispatched run id on the marker, with retries and a fallback post.
finalize() {
  local repo="$1" server_url="$2" pr="$3" token_user="$4" review="$5" round="$6" head="$7" run_id="$8" marker_id="$9"
  local run_url="$server_url/$repo/actions/runs/$run_id"
  local marker body ok=0
  marker="$(aw_state_marker "$review" "$pr" "$round" "$run_id" "$head")"
  body="🤖 PR Fixer is working on Copilot review [\`$review\`]($server_url/$repo/pull/$pr#pullrequestreview-$review) (round $round, fixes by [@$token_user]($server_url/$token_user)) — [run \\#$run_id]($run_url) for head \`${head:0:7}\`. $marker"

  local _
  for _ in 1 2 3; do
    if printf '%s' "$body" | body_json | gh api -X PATCH "repos/$repo/issues/comments/$marker_id" --input - >/dev/null; then
      ok=1
      break
    fi
    sleep 3
  done
  if [ "$ok" = "1" ]; then return 0; fi

  echo "PR #$pr: could not update marker $marker_id for run $run_id; posting fallback" >&2
  if ! printf '%s' "$body" | body_json | gh api -X POST "repos/$repo/issues/$pr/comments" --input - >/dev/null; then
    echo "PR #$pr: could not persist outcome for run $run_id; ending this cycle" >&2
  fi
  return 0
}

# Dispatches the fixer. Returns 0 when a run was dispatched (ends the cycle),
# non-zero to try the next PR.
dispatch() {
  local repo="$1" server_url="$2" pr="$3" token_user="$4" review="$5" round="$6" head="$7" dispatch_token="$8" marker_id="$9"
  local aw_context out run_id
  aw_context="$(printf '{"item_type":"pull_request","item_number":%d}' "$pr")"
  if ! out="$(GH_TOKEN="$dispatch_token" gh aw run pr-fix --repo "$repo" --raw-field "aw_context=$aw_context" 2>&1)"; then
    echo "Dispatch failed for PR #$pr; marker stays pending (will retry)" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
  run_id="$(printf '%s\n' "$out" | grep -oE '/actions/runs/[0-9]+' | head -n 1 | grep -oE '[0-9]+' || true)"
  if [ -z "$run_id" ]; then
    echo "PR #$pr: dispatched run not identified; marker stays pending (will retry)"
    return 1
  fi
  finalize "$repo" "$server_url" "$pr" "$token_user" "$review" "$round" "$head" "$run_id" "$marker_id"
  return 0
}

# Returns 0 when a run was dispatched, non-zero when this PR is skipped.
process() {
  local repo="$1" server_url="$2" pr="$3" token_user="$4" max_rounds="$5" dispatch_token="$6"
  local head state prev_review prev_round prev_run prev_comment
  head="$(gh_get "repos/$repo/pulls/$pr" | jq -r '.head.sha')"

  state="$(latest_marker "$repo" "$pr" "$token_user" "$STATE_NEEDLE")"
  prev_review="$(marker_field "$state" review)"
  prev_round="$(marker_field "$state" round)"
  prev_run="$(marker_field "$state" run)"
  prev_comment="$(jq -r '.id // ""' <<<"$state")"
  if [ "$prev_run" = "none" ]; then prev_run=""; fi

  local prev_concl=""
  if [ -n "$prev_run" ]; then
    if ! prev_concl="$(read_conclusion "$repo" "$prev_run")"; then
      echo "PR #$pr: could not read run $prev_run; will retry next cycle"
      return 1
    fi
    if is_failure_conclusion "$prev_concl"; then
      if ! report_failure "$repo" "$server_url" "$pr" "$prev_run" "$prev_concl" "$token_user"; then
        echo "PR #$pr: could not report run $prev_run failure; will retry next cycle"
        return 1
      fi
    fi
  fi

  local review
  review="$(copilot_review_on "$repo" "$pr" "$head")"
  if [ -z "$review" ]; then
    echo "PR #$pr: no Copilot review on the current head"
    return 1
  fi

  if [ "$prev_review" = "$review" ]; then
    if [ -z "$prev_run" ]; then
      echo "PR #$pr: review $review has no observed run; re-dispatching"
    elif is_failure_conclusion "$prev_concl"; then
      echo "PR #$pr: previous run $prev_run concluded $prev_concl; re-dispatching review $review"
    else
      echo "PR #$pr: review $review already dispatched ($prev_concl)"
      return 1
    fi
  fi

  local round=$(( ${prev_round:-0} + 1 ))
  if [ "$round" -gt "$max_rounds" ]; then
    echo "PR #$pr: reached $max_rounds rounds; leaving the rest to a human"
    return 1
  fi

  local head_now
  head_now="$(gh_get "repos/$repo/pulls/$pr" | jq -r '.head.sha')"
  if [ "$head_now" != "$head" ]; then
    echo "PR #$pr: head moved from $head to $head_now; not dispatching (will re-evaluate)"
    return 1
  fi

  local marker_id
  marker_id="$(write_pending "$repo" "$server_url" "$pr" "$token_user" "$review" "$round" "$head" "$prev_comment")"
  echo "PR #$pr: dispatching fixer for review $review (round $round)"
  dispatch "$repo" "$server_url" "$pr" "$token_user" "$review" "$round" "$head" "$dispatch_token" "$marker_id"
}

main() {
  set -euo pipefail
  local repo="${REPO:?REPO must be set}"
  local server_url="${SERVER_URL:?SERVER_URL must be set}"
  local author="${AUTHOR:-asbjornu}"
  local max_rounds="${MAX_ROUNDS:-6}"
  local dispatch_token="${GH_AW_DISPATCH_TOKEN:-}"
  local token_user wf_id
  token_user="$(gh_login)"

  wf_id="$(gh_get "repos/$repo/actions/workflows" \
    | jq -r --arg p "$LOCK_PATH" '.workflows[] | select(.path == $p) | .id' | head -n 1)"
  if [ -z "$wf_id" ]; then
    echo "pr-fix workflow not on the default branch yet; nothing to do"
    return 0
  fi
  if fixer_pending "$repo" "$wf_id"; then
    echo "A PR Fixer run is already pending; skipping this cycle"
    return 0
  fi

  while IFS=$'\t' read -r pr_author pr; do
    [ -n "$pr" ] || continue
    [ "$pr_author" = "$author" ] || continue
    if process "$repo" "$server_url" "$pr" "$token_user" "$max_rounds" "$dispatch_token"; then
      break
    fi
  done < <(gh_all "repos/$repo/pulls?state=open&per_page=100" \
    | jq -r '.[] | select(.draft == false and (.head.repo.full_name == .base.repo.full_name)) | "\(.user.login)\t\(.number)"')
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
