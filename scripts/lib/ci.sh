# shellcheck shell=bash
# shellcheck disable=SC2034  # the marker needles are consumed by the scripts
#
# Shared helpers for the CI scripts under scripts/. Sourced, never executed.
# Requires gh, jq and (for the squash workflow) git on PATH.
#
# The gh wrappers return raw JSON, or (for list endpoints) a single JSON array
# with every page merged; callers parse it with jq, which keeps the logic
# testable with a fake `gh` that only has to emit JSON.

readonly FIXER_BOT="github-actions[bot]"
readonly COPILOT_LOGINS="copilot-pull-request-reviewer[bot],copilot-pull-request-reviewer,Copilot,copilot"

# --- gh wrappers -------------------------------------------------------------

# Single-object endpoint, as raw JSON.
gh_get() { gh api "$1"; }
# List endpoint, all pages merged into one JSON array. `--paginate` emits one
# JSON document per page, so slurp them (jq -s) and `add` the arrays together.
gh_all() { gh api --paginate "$1" | jq -cs 'add // []'; }
# Authenticated user login.
gh_login() { gh api user | jq -r '.login'; }
# POST/PATCH with a raw JSON body on stdin.
gh_post() { gh api -X POST "$1" --input -; }
gh_patch() { gh api -X PATCH "$1" --input -; }
gh_delete() { gh api -X DELETE "$1" >/dev/null; }

# --- JSON helpers ------------------------------------------------------------

# Read stdin as a string and wrap it as {"body": "..."}.
body_json() { jq -Rs '{body: .}'; }

# all_bot <TAB-separated logins>: success if non-empty and every entry is the
# fixer bot.
all_bot() {
  [ -n "$1" ] || return 1
  printf '%s\n' "$1" | tr '\t' '\n' \
    | awk -v b="$FIXER_BOT" 'NF && $0 != b { bad = 1 } END { exit(bad ? 1 : 0) }'
}

# is_copilot <login>: success if the login is one of the Copilot reviewer names.
is_copilot() {
  local logins=",${COPILOT_LOGINS},"
  [[ "$logins" == *",$1,"* ]]
}

# --- markers -----------------------------------------------------------------

readonly STATE_NEEDLE='<!-- aw-pr-fix-state'
readonly ANCHOR_NEEDLE='<!-- aw-pr-fix-squash-anchor'

aw_state_marker() {
  printf '<!-- aw-pr-fix-state review=%s pr=%s round=%s run=%s head=%s -->' "$1" "$2" "$3" "$4" "$5"
}

aw_anchor_marker() {
  printf '<!-- aw-pr-fix-squash-anchor review=%s head=%s -->' "$1" "$2"
}

aw_failure_marker() { printf '<!-- aw-pr-fix-failure run=%s -->' "$1"; }

# latest_marker <repo> <pr> <who> <needle>: the newest comment authored by <who>
# whose body contains <needle>, as compact JSON, or the literal `null`.
latest_marker() {
  local repo="$1" pr="$2" who="$3" needle="$4"
  gh_all "repos/$repo/issues/$pr/comments?per_page=100" \
    | jq -c --arg who "$who" --arg n "$needle" \
      '[.[] | select((.body | contains($n)) and (.user.login == $who))]
       | sort_by(.created_at) | last // null'
}

# marker_field <comment-json> <field>: the field value from a marker body, or "".
marker_field() {
  jq -r --arg f "$2" '((.body // "") | capture($f + "=(?<v>[0-9a-zA-Z]+)") | .v) // ""' <<<"$1"
}
