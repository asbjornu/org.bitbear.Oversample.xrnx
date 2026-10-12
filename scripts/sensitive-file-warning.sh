#!/usr/bin/env bash
#
# Flags pull requests that modify files which deserve extra human scrutiny.
#
# Extracted from .github/workflows/sensitive-file-warning.yml so the logic can be
# linted (shellcheck) and unit-tested (bats). Inputs come from the environment:
#   GH_TOKEN  (read by the gh CLI)
#   REPO      owner/name
#   PR        pull request number
#   GH_BIN    gh executable to use (default: gh); override in tests.
#
# It maintains a single sticky comment per PR and removes it once the PR no
# longer touches anything sensitive.

readonly MARKER='<!-- sensitive-file-warning -->'

# Global so the EXIT trap can still see it after main()'s locals go out of
# scope (direct execution enables `set -u`).
TMP_DIR=''

# Paths that warrant extra review. Mirrors gh-aw's protected-file set plus this
# repository's CI scripts, dotfiles and dependency manifests.
sensitive_patterns() {
  cat <<'PATTERNS'
^\.github/
^\.agents/
^scripts/
^\.luacheckrc$
^\.gitattributes$
^\.gitignore$
^CODEOWNERS$
^AGENTS\.md$
^README\.md$
^LICENSE$
^(package|package-lock)\.json$
^(yarn|pnpm-lock)\.(lock|yaml)$
PATTERNS
}

# Pure: read newline-separated file names on stdin, print those matching any
# pattern in the patterns file, preserving input order. Always exits 0 so it is
# safe under `set -e` in a command substitution.
select_sensitive_files() {
  local patterns_file="$1"
  grep -E -f "$patterns_file" || true
}

# Pure: read matched file names on stdin, print the sticky-comment body.
build_comment_body() {
  local tick='`' file
  printf '%s\n' "$MARKER" '> [!WARNING]' \
    '> This pull request modifies files that deserve extra scrutiny:'
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    printf -- '- %s%s%s\n' "$tick" "$file" "$tick"
  done
  printf '\nA human should confirm these changes are intended before merge.\n'
}

main() {
  local gh_bin="${GH_BIN:-gh}"
  : "${REPO:?REPO must be set}"
  : "${PR:?PR must be set}"

  local patterns files hits comment_id body
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  patterns="$TMP_DIR/patterns.txt"
  sensitive_patterns > "$patterns"

  files="$("$gh_bin" api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" --jq '.[].filename')"
  hits="$(printf '%s\n' "$files" | select_sensitive_files "$patterns")"

  comment_id="$("$gh_bin" api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
    --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" | head -n 1 || true)"

  if [[ -z "$hits" ]]; then
    echo "No sensitive files touched."
    if [[ -n "$comment_id" ]]; then
      "$gh_bin" api -X DELETE "repos/$REPO/issues/comments/$comment_id" >/dev/null
    fi
    return 0
  fi

  body="$(printf '%s\n' "$hits" | build_comment_body)"
  if [[ -n "$comment_id" ]]; then
    printf '%s' "$body" | jq -Rs '{body: .}' \
      | "$gh_bin" api -X PATCH "repos/$REPO/issues/comments/$comment_id" --input - >/dev/null
  else
    printf '%s' "$body" | jq -Rs '{body: .}' \
      | "$gh_bin" api -X POST "repos/$REPO/issues/$PR/comments" --input - >/dev/null
  fi
  echo "Posted sensitive-file warning for: $hits"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
