#!/usr/bin/env bash
#
# Requests a Copilot review for the current head of a same-repo PR authored by
# the fixer author, unless the head already carries one or only holds fixer
# commits under an active dispatch. See copilot-review-request.yml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ci.sh"

# True (exit 0) when the head only holds fixer commits under an active dispatch,
# in which case the squash workflow will re-request on our behalf.
quiet_skip_for_fixer_head() {
  local repo="$1" pr="$2" token_user="$3" head="$4"
  local fixup_authors
  fixup_authors="$(gh_all "repos/$repo/pulls/$pr/commits?per_page=100" \
    | jq -r '[.[] | select(.commit.message | startswith("fixup!")) | (.author.login // "unknown")] | join("\t")')"
  all_bot "$fixup_authors" || return 1

  local state marker_head
  state="$(latest_marker "$repo" "$pr" "$token_user" "$STATE_NEEDLE")"
  marker_head="$(marker_field "$state" head)"

  local status="diverged" total=0 seen=0 truncated=0 range_authors=""
  if [ -n "$marker_head" ]; then
    local cmp
    cmp="$(gh_get "repos/$repo/compare/$marker_head...$head" || echo '{}')"
    status="$(jq -r '.status // "diverged"' <<<"$cmp")"
    total="$(jq -r '.total_commits // 0' <<<"$cmp")"
    seen="$(jq -r '(.commits // []) | length' <<<"$cmp")"
    range_authors="$(jq -r '(.commits // [])[] | (.author.login // "unknown")' <<<"$cmp" | tr '\n' '\t')"
    if [ "${total:-0}" -gt "${seen:-0}" ] 2>/dev/null; then truncated=1; fi
  fi

  if [ "$truncated" -eq 0 ] \
    && { [ "$status" = "ahead" ] || [ "$status" = "identical" ]; } \
    && all_bot "$range_authors"; then
    echo "Head has only fixer commits under an active dispatch; the squash workflow will re-request"
    return 0
  fi
  echo "Fixer fixup! commits present but no purely-fixer active dispatch; requesting a review"
  return 1
}

# Number of Copilot reviews already posted against the given head.
copilot_reviews_on() {
  local repo="$1" pr="$2" head="$3"
  gh_all "repos/$repo/pulls/$pr/reviews?per_page=100" \
    | jq --arg head "$head" --arg cp "$COPILOT_LOGINS" '
        ($cp | split(",")) as $cops
        | [.[] | select((.user.login as $l | $cops | index($l)) and (.commit_id == $head))]
        | length'
}

request_review() {
  local repo="$1" pr="$2"
  # Let a failed request fail the run: there may be no further event to retry
  # it, so reporting "Requested" after a swallowed error would strand the head
  # unreviewed.
  printf '%s' '{"reviewers":["copilot-pull-request-reviewer[bot]"]}' \
    | gh api -X POST "repos/$repo/pulls/$pr/requested_reviewers" --input - >/dev/null
}

main() {
  set -euo pipefail
  local repo="${REPO:?REPO must be set}"
  local pr="${PR:?PR must be set}"
  local author="${AUTHOR:-asbjornu}"
  local token_user
  token_user="$(gh_login)"

  local pull state draft pr_author head_repo head
  pull="$(gh_get "repos/$repo/pulls/$pr")"
  state="$(jq -r '.state' <<<"$pull")"
  draft="$(jq -r '.draft' <<<"$pull")"
  pr_author="$(jq -r '.user.login' <<<"$pull")"
  head_repo="$(jq -r '.head.repo.full_name' <<<"$pull")"
  head="$(jq -r '.head.sha' <<<"$pull")"

  if [ "$state" != "open" ]; then
    echo "PR #$pr is $state; skipping"
    return 0
  fi
  if [ "$draft" = "true" ]; then
    echo "PR #$pr is a draft; skipping"
    return 0
  fi
  if [ "$pr_author" != "$author" ]; then
    echo "PR #$pr author is $pr_author, not $author; skipping"
    return 0
  fi
  if [ "$head_repo" != "$repo" ]; then
    echo "PR #$pr is from a fork ($head_repo); skipping"
    return 0
  fi

  if quiet_skip_for_fixer_head "$repo" "$pr" "$token_user" "$head"; then
    return 0
  fi

  local reviewed
  reviewed="$(copilot_reviews_on "$repo" "$pr" "$head")"
  if [ "$reviewed" != "0" ]; then
    echo "PR #$pr head $head already has a Copilot review; skipping"
    return 0
  fi

  request_review "$repo" "$pr"
  echo "Requested a Copilot review for PR #$pr at $head"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
