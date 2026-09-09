# AGENTS.md — Oversample Renoise tool

Renoise Lua tool (`org.bitbear.Oversample.xrnx`) that automates VST/AU
**oversampling** for FabFilter plugins (Pro-Q 3, Pro-C 2, Pro-L 2, Pro-MB,
Saturn 2). The VST3 version of these plugins expose no host oversampling
parameter, so oversampling is driven by **patching the plugin state-chunk
XML** (`<DeviceChunkMachineData>` base64 VST3 state) at known byte
offsets/signatures (`core.known_osig`). The "Set" button writes the chunk;
`Minimize`/`Maximize` only move UI controls.

Saturn 2 oversampling is **two independent axes** ("High Quality"
Off/Good/Superb + "Linear Phase" Off/On), shown as two separate dropdowns
with a combined target `"axis1 / axis2"` for chunk patching
(`core.known_osig_axes`, `osig_multi_axis`). The Linear Phase dropdown
remains available even when High Quality is Off.

## Repo layout

- `main` worktree: `~/Dev/org.bitbear.Oversample.xrnx`. A session may start
  here, but this is **not the installed tool**. Its implementation differs
  from the deployed branch.
- **Make tool changes, tests, and related documentation updates in
  `renoise/3.5.4`**, unless the user explicitly names another branch (as
  with updates to this file in `main`). Its worktree is
  `~/Library/Preferences/Renoise/V3.5.4/Scripts/Tools/org.bitbear.Oversample.xrnx`.
- Run `git worktree list` from the current repository and use the absolute
  path listed for the target branch; it is authoritative if the paths above
  differ. `~` denotes the current user's home directory, not a literal path
  component. Use the resolved absolute path for tools that do not expand
  `~`.
- Verify `git status --short --branch` in the target worktree before
  editing. Use that directory as the working directory for tests and Git
  commands; do not switch branches in `main` or copy its older
  implementation over the installed tool.
- Worktrees are separate directories, not symlinks or automatically
  synchronized copies. Changes in `main` do not affect Renoise. After
  editing the installed tool, use **Tools > Reload all tools**, then reopen
  Oversample. A screenshot that differs from the source is a reason to
  check the worktree.
- Other `renoise/3.x.x` branches are parallel worktrees.
  `backup/before-cleanup` preserves pre-cleanup history.
- Key files: `Oversample/Oversample.lua` (UI + glue),
  `Oversample/oversample_core.lua` (logic/constants),
  `Oversample/ProcessSlicer.lua`, `main.lua` (menu entry `Main
  Menu:Tools:Oversample`).

## Commit / git rules

- **GPG-sign every commit**. Homebrew is installed and `gpg` is installed
  in Homebrew. Find it and use it to sign all commits.
- Syntax check before committing: `/usr/local/bin/luac -p
  Oversample/oversample_core.lua && /usr/local/bin/luac -p
  Oversample/Oversample.lua`.
- Commit every meaningful change, ensuring that each commit represents a
  logical unit of work.
- When fixing code that was added in a previous commit on the same branch,
  perform a "fixup" and squash the fix into the original commit.
- Keep commit message headers shorter than 50 characters. If more detail is
  needed, repeat the full header in the commit message body. Wrap the body
  at 70 characters per line.
- Do not merge, deploy, or leave duplicate edits in other worktrees unless
  requested.

## Renoise ViewBuilder layout rules (learned the hard way)

- **Aligned columns = fixed widths.** Give every control in a column the
  same `width` (estimate from widest known label; factor
  `~CONTENT_HEIGHT*0.3 + padding`, no text metrics exist). `CONTENT_HEIGHT
  = renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT`.
- **`width = "*"` is REJECTED** for rows/spaces/popups/buttons (runtime
  error: *"expecting a percentage string or number argument for property
  'width'"*). Valid width values are **numbers** or **percentage strings**
  (e.g. `"100%"`).
- **`vb:space` accepts only number/percentage width, not `"*"`**, and a
  percentage there is unreliable.
- **`width = "100%"` on a row inside an auto-sized column collapses the row
  to zero width** (percentage is relative to the auto-sized parent → 0).
  Never use percentage width to "fill".
- **`vb:horizontal_aligner` `mode="justify"` spreads space between ALL its
  direct children.** With exactly two children it pushes the 2nd to the
   right edge — this works for the bottom status bar, but it **jumbled the
   fixed columns in settings rows**. Avoid for aligned column layouts. Give
   the footer an explicit width matching the populated settings row; do not
   rely on automatic filling or shrinking.
- **To pin a control (e.g. the `+` button) to the right edge of every row
  while keeping columns aligned:** *always reserve* each column's space.
  Put optional secondary controls inside a **fixed-width, fixed-height
  `vb:row`**, then hide the controls when unused. The container preserves
  alignment without drawing empty disabled dropdowns. Only the newest
  settings row retains the `+` button.
- **Hide the old control before showing its replacement** (popup/slider or
  popup/label). Showing both even briefly can expand the dialog, leaving
  unused space after the old control disappears.
- **`vb:text` expands for longer messages but does not automatically shrink
  for shorter ones.** A final `"Done."` does not prove the status control
  is small. The deployed footer uses a one-control- height
  `vb:multiline_text`, `style="body"`, with a fixed width that leaves room
  for all three buttons. `SETTINGS_WIDTH` includes the visible columns,
  `+`, and spacing; the footer must not exceed it.

## Tests and verification

- Run from the `renoise/3.5.4` worktree, with LuaUnit installed via the
  rockspec dependencies:

  ```sh
  eval "$(luarocks path)"
  lua test/oversample_core_test.lua
  lua test/oversample_ui_test.lua
  luajit test/oversample_core_test.lua
  luajit test/oversample_ui_test.lua
  ```

- CI runs both suites on Lua 5.1 and LuaJIT. Local `lua` may be newer, so
  do not treat its success alone as Renoise compatibility. Use `[^%z]+`,
  not a literal NUL inside a pattern character class, when splitting
  NUL-delimited fields on Lua 5.1/LuaJIT.
- Core tests target the current multi-state API: `diff_blobs_multi`,
  `patch_blob`, `detect_label`, and `encode_osig`/`decode_osig` entries
  with a `values` map. Do not resurrect removed `diff_blobs`,
  `toggle_blob`, or old `off`/`on` entry shapes just to satisfy stale
  tests.
- `test/oversample_ui_test.lua` runs the actual dialog code against a small
  ViewBuilder stub. It covers footer/status sizing, hidden secondary
  fields, Saturn's independent axis, transient control overlap, and
  newest-row `+` placement. Keep these tests outside the core coverage run.
- Stub tests do **not** verify native rendering, font metrics, clipping, or
  notifier timing. Check in Renoise after reload, including long status
  messages, Minimize/Maximize, switching devices, and adding rows. Report
  visual verification as pending unless actually performed.
- After the test repair, 66 core tests and 6 UI tests passed on Lua 5.5 and
  LuaJIT; the earlier nine stale core-test errors are no longer an accepted
  baseline. Run test lint, Lua syntax checks, and `git diff --check` before
  reporting completion.

## User's UI preferences (enforced)

- Columns must stay aligned (fixed widths).
- No excessive trailing space after the `+` button; `+` should be flush
  right.
- Status text must not force the dialog wider; preserve the bounded footer
  layout described above.
- Unused secondary Value fields must be visually empty, not empty disabled
  controls.
- Secondary labels are right-aligned and colon-suffixed (e.g. `"Linear
  Phase:"`).
- The user reverts fast when layout looks jumbled — prefer minimal,
  alignment-preserving changes; verify in Renoise.
