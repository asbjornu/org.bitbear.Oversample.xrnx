---
name: oversample-tests
description: How to run and verify the Oversample Lua test suites (core + UI + strict-globals load) on Lua 5.1/LuaJIT, the accepted passing baseline, Lua 5.1 NUL-split caveats, and the Renoise visual-check steps. Load before running tests or reporting test results.
license: MIT
compatibility: opencode
---

# Tests and verification

## Run the suites
Run from the `renoise/3.5.4` worktree, with LuaUnit installed via the rockspec
dependencies:

```sh
eval "$(luarocks path)"
lua test/oversample_core_test.lua
lua test/oversample_ui_test.lua
lua test/oversample_load_test.lua
luajit test/oversample_core_test.lua
luajit test/oversample_ui_test.lua
luajit test/oversample_load_test.lua
```

## Lua version caveats
- CI runs all three suites on Lua 5.1 and LuaJIT. Local `lua` may be newer, so
  do not treat its success alone as Renoise compatibility.
- Use `[^%z]+`, not a literal NUL inside a pattern character class, when
  splitting NUL-delimited fields on Lua 5.1/LuaJIT.

## What the tests target
- Core tests target the current multi-state API: `diff_blobs_multi`,
  `patch_blob`, `detect_label`, and `encode_osig`/`decode_osig` entries with a
  `values` map. Do not resurrect removed `diff_blobs`, `toggle_blob`, or old
  `off`/`on` entry shapes just to satisfy stale tests.
- `test/oversample_ui_test.lua` runs the actual dialog code against a small
  ViewBuilder stub. It covers footer/status sizing, hidden secondary fields,
  Saturn's independent axis, transient control overlap, and newest-row `+`
  placement. Keep these tests outside the core coverage run.
- `test/oversample_load_test.lua` `require`s the entry module under a strict
  globals sandbox that raises on undeclared global reads *and* writes, and
  checks that no implementation leaks into globals. Run it in its own process
  (it temporarily installs a metatable on `_G`).

## Verification before reporting done
- Stub tests do **not** verify native rendering, font metrics, clipping, or
  notifier timing. Check in Renoise after reload, including long status
  messages, Minimize/Maximize, switching devices, and adding rows. Report
  visual verification as pending unless actually performed.
- Accepted baseline: the core, UI, and strict-globals load suites pass on Lua
  5.5/Lua 5.1 and LuaJIT (the load suite has 3 tests); the earlier nine stale
  core-test errors are no longer an accepted baseline.
- Run test lint, Lua syntax checks, and `git diff --check` before reporting
  completion.

## Lua syntax check (also a commit gate)
```sh
/usr/local/bin/luac -p Oversample/*.lua
```
