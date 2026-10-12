#!/usr/bin/env bash
#
# Folds the fixer's fixup! commits on a PR branch and force-pushes, then records
# a squash anchor so later runs know which head was already folded. The branch
# is fixer-managed between rounds. See pr-fix-squash.yml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ci.sh"

# Prefer this workflow's own anchor for the same round, then the orchestrator's
# dispatch head, then an earlier anchor. The dispatch head is used only while it
# is still an ancestor of HEAD.
choose_anchor() {
  local published="$1" anchor_review="$2" state_review="$3" state_head="$4"
  if [ -n "$state_review" ] && [ "$anchor_review" = "$state_review" ] && [ -n "$published" ] \
    && git merge-base --is-ancestor "$published" HEAD; then
    printf '%s' "$published"
    return 0
  fi
  if [ -n "$state_head" ] && git merge-base --is-ancestor "$state_head" HEAD; then
    printf '%s' "$state_head"
    return 0
  fi
  if [ -n "$published" ] && git merge-base --is-ancestor "$published" HEAD; then
    echo "Dispatch head is not an ancestor; keeping the published anchor $published" >&2
    printf '%s' "$published"
    return 0
  fi
  return 0
}

verdict_of() {
  jq -r '
    (.["commits"] // []) as $c
    | if ($c | length) == 0 then "empty"
      elif ($c | any((.author.login // "unknown") != "github-actions[bot]")) then "mixed"
      elif ($c | any((.commit.message | split("\n")[0]) | startswith("fixup! "))) then "fixups"
      else "normal" end' <<<"$1"
}

# Request a recovery review, retrying a transient failure. Returns non-zero if
# every attempt fails: a failed rebase fires no synchronize and the
# review-request workflow has already deferred to this squash, so swallowing the
# error would make the job green while the fixer loop stalls.
request_review() {
  local repo="$1" pr="$2" _
  for _ in 1 2 3; do
    if printf '%s' '{"reviewers":["copilot-pull-request-reviewer[bot]"]}' \
      | gh api -X POST "repos/$repo/pulls/$pr/requested_reviewers" --input - >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  echo "Could not request a review after retries; the fixer loop may stall" >&2
  return 1
}

write_anchor() {
  local repo="$1" pr="$2" review="$3" head="$4" anchor_id="$5"
  local body
  body="$(aw_anchor_marker "$review" "$head")"
  if [ -n "$anchor_id" ]; then
    printf '%s' "$body" | body_json | gh api -X PATCH "repos/$repo/issues/comments/$anchor_id" --input - >/dev/null 2>&1
  else
    printf '%s' "$body" | body_json | gh api -X POST "repos/$repo/issues/$pr/comments" --input - >/dev/null 2>&1
  fi
}

# Rebase, push, verify the remote head, then record the anchor. Returns non-zero
# when the round could not be recovered (the caller exits non-zero).
verify_and_anchor() {
  local repo="$1" pr="$2" head_ref="$3" review="$4" anchor_id="$5" new_head="$6"
  local remote_head="" verified=0 anchor_ok=0 _
  for _ in 1 2 3; do
    if remote_head="$(git ls-remote origin "refs/heads/$head_ref" 2>/dev/null | cut -f1)"; then
      verified=1
      break
    fi
    remote_head=""
    sleep 3
  done

  if [ "$verified" = "1" ] && [ "$remote_head" = "$new_head" ]; then
    echo "Squashed and force-pushed $head_ref"
    for _ in 1 2 3; do
      if write_anchor "$repo" "$pr" "$review" "$new_head" "$anchor_id"; then
        anchor_ok=1
        break
      fi
      sleep 3
    done
    if [ "$anchor_ok" = "1" ]; then return 0; fi
    echo "Could not record the squash anchor at $new_head" >&2
  else
    echo "Squash did not land or could not be verified (remote at ${remote_head:0:12})" >&2
  fi

  echo "Requesting a fresh review to recover the round" >&2
  request_review "$repo" "$pr"
  return 1
}

run_rebase() {
  local repo="$1" pr="$2" base="$3" head_ref="$4" review="$5" anchor_id="$6"
  if ! GIT_SEQUENCE_EDITOR="bash $SCRIPT_DIR/seq-editor.sh" GIT_EDITOR=: \
    git rebase -i --rebase-merges "$base"; then
    git rebase --abort >/dev/null 2>&1 || true
    echo "Squash failed; requesting a review" >&2
    request_review "$repo" "$pr"
    return 1
  fi
  local new_head
  new_head="$(git rev-parse HEAD)"
  git push --force-with-lease origin "HEAD:$head_ref" >/dev/null 2>&1 || true
  verify_and_anchor "$repo" "$pr" "$head_ref" "$review" "$anchor_id" "$new_head"
}

main() {
  set -euo pipefail
  local repo="${REPO:?REPO must be set}"
  local pr="${PR:?PR must be set}"
  local base_ref="${BASE_REF:?BASE_REF must be set}"
  local head_ref="${HEAD_REF:?HEAD_REF must be set}"
  local token_user
  token_user="$(gh_login)"

  git config user.name "$FIXER_BOT"
  git config user.email "$FIXER_BOT@users.noreply.github.com"
  local base
  base="$(git merge-base "origin/$base_ref" HEAD)"

  local state anchor anchor_id published anchor_review state_review state_head
  state="$(latest_marker "$repo" "$pr" "$token_user" "$STATE_NEEDLE")"
  anchor="$(latest_marker "$repo" "$pr" "$token_user" "$ANCHOR_NEEDLE")"
  anchor_id="$(jq -r '.id // ""' <<<"$anchor")"
  published="$(marker_field "$anchor" head)"
  anchor_review="$(marker_field "$anchor" review)"
  state_review="$(marker_field "$state" review)"
  state_head="$(marker_field "$state" head)"

  local anchor_head
  anchor_head="$(choose_anchor "$published" "$anchor_review" "$state_review" "$state_head")"
  if [ -z "$anchor_head" ]; then
    echo "No active fixer dispatch for this head; nothing to squash"
    return 0
  fi

  local head cmp total seen verdict
  head="$(git rev-parse HEAD)"
  cmp="$(gh_get "repos/$repo/compare/$anchor_head...$head" 2>/dev/null || echo '{}')"
  total="$(jq -r '.total_commits // 0' <<<"$cmp")"
  seen="$(jq -r '(.commits // []) | length' <<<"$cmp")"
  if [ "${total:-0}" -gt "${seen:-0}" ] 2>/dev/null; then
    echo "Compare range truncated; refusing to rewrite"
    return 0
  fi

  verdict="$(verdict_of "$cmp")"
  case "$verdict" in
    fixups)
      run_rebase "$repo" "$pr" "$base" "$head_ref" "$state_review" "$anchor_id"
      ;;
    normal)
      echo "Only fixer normal commits since dispatch; requesting a review"
      request_review "$repo" "$pr"
      return 0
      ;;
    *)
      echo "Commits since the dispatch head are not purely fixer fixups; nothing to squash"
      return 0
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
