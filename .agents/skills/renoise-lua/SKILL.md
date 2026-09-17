---
name: renoise-lua
description: Constraints when editing Lua code for this Renoise tool
license: MIT
compatibility: opencode
---

- **Pure-Lua only.** No external packages, no C modules (xml2lua/LuaExpat won't
  load in the Renoise sandbox). Vendor pure-Lua if a dependency is needed.
- **Lua 5.1/LuaJIT target.** Renoise runs Lua 5.1 and LuaJIT; avoid 5.2+ syntax
  (e.g. `goto`/`::label::`) and verify with `luajit`, not just the newer local
  `lua`. See the `oversample-tests` skill.
- Lua patterns have **no `|` alternation**; use character classes (e.g.
  `[%s,]`) instead.
- **Keep `luacheck` clean** (`luacheck .`, 0 warnings). Declare legitimate
  tool globals in `.luacheckrc`, never silence warnings inline.
- Commit messages: terse, no "the user" references.
