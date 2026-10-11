#!/usr/bin/env bash
#
# GIT_SEQUENCE_EDITOR for pr-fix-squash.sh. Reads the rebase todo path from
# ARGV[0], folds every fixup! commit into its target, and writes it back.

main() {
  set -euo pipefail
  local todo="${1:?usage: seq-editor.sh <todo-file>}"

  local -a lines=() cmd=() sha=() subj=()
  local line rest token resolved s
  mapfile -t lines < "$todo"
  local n=${#lines[@]}

  local i
  for ((i = 0; i < n; i++)); do
    line="${lines[$i]}"
    cmd[i]="${line%% *}"
    rest="${line#* }"
    case "$rest" in
      -C\ * | -c\ *) rest="${rest#* }" ;;
    esac
    token="${rest%% *}"
    resolved="$(git rev-parse --verify -q "${token}^{commit}" 2>/dev/null || true)"
    sha[i]="${resolved:-$token}"
    s="$(git log -1 --format=%s "${sha[$i]}" 2>/dev/null || true)"
    subj[i]="${s:-${rest#* }}"
  done

  local -A moved=() move_to=()
  local body target want found k j
  for ((i = 0; i < n; i++)); do
    [[ "${subj[$i]:-}" == "fixup! "* ]] || continue

    found=""
    body="$(git log -1 --format=%B "${sha[$i]}" 2>/dev/null || true)"
    target="$(printf '%s\n' "$body" | sed -n 's/^aw-fixup-target=\([0-9a-f]\{7,40\}\)[[:space:]]*$/\1/p' | tail -n 1)"
    if [ -n "$target" ]; then
      for ((k = 0; k < n; k++)); do
        if [ "${sha[$k]}" = "$target" ] && [ "${cmd[$k]}" = "pick" ]; then
          found=$k
          break
        fi
      done
    fi
    if [ -z "$found" ]; then
      want="${subj[$i]#fixup! }"
      j=$((i - 1))
      while [ "$j" -ge 0 ]; do
        if [ "${cmd[$j]}" = "pick" ] && [ "${subj[$j]}" = "$want" ]; then
          found=$j
          break
        fi
        j=$((j - 1))
      done
    fi
    if [ -z "$found" ]; then
      echo "seq-editor: no target commit for fixup '${subj[$i]}'" >&2
      exit 1
    fi

    moved[$i]=1
    move_to[$found]="${move_to[$found]:-} ${sha[$i]}"
  done

  local out s2
  out="$(mktemp)"
  for ((i = 0; i < n; i++)); do
    [ -z "${moved[$i]:-}" ] || continue
    printf '%s\n' "${lines[$i]}" >> "$out"
    if [ -n "${move_to[$i]:-}" ]; then
      for s2 in ${move_to[$i]}; do
        printf 'fixup %s\n' "$s2" >> "$out"
      done
    fi
  done
  mv "$out" "$todo"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
