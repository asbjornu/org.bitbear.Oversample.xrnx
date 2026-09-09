---
name: oversample-tests
description: How to run and verify the Oversample Lua test suites (core + UI) on Lua 5.1/LuaJIT, the accepted passing baseline, Lua 5.1 NUL-split caveats, and the Renoise visual-check steps. Load before running tests or reporting test results.
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
luajit test/oversample_core_test.lua
luajit test/oversample_ui_test.lua
```

## Lua version caveats
- CI runs both suites on Lua 5.1 and LuaJIT. Local `lua` may be newer, so do
  not treat its success alone as Renoise compatibility.
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

## Verification before reporting done
- Stub tests do **not** verify native rendering, font metrics, clipping, or
  notifier timing. Check in Renoise after reload, including long status
  messages, Minimize/Maximize, switching devices, and adding rows. Report
  visual verification as pending unless actually performed.
- Accepted baseline: 66 core tests and 6 UI tests passed on Lua 5.5 and LuaJIT;
  the earlier nine stale core-test errors are no longer an accepted baseline.
- Run test lint, Lua syntax checks, and `git diff --check` before reporting
  completion.

## Lua syntax check (also a commit gate)
```sh
/usr/local/bin/luac -p Oversample/oversample_core.lua && \
/usr/local/bin/luac -p Oversample/Oversample.lua
```
