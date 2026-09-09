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

## Renoise ViewBuilder layout rules

Detailed, load-on-demand. See the `renoise-viewbuilder-layout` skill
(`.agents/skills/renoise-viewbuilder-layout/SKILL.md`) for fixed-width column
rules, `width` constraints, `justify` behavior, right-edge pinning, control
swapping, and footer/status sizing.

## Tests and verification

Detailed, load-on-demand. See the `oversample-tests` skill
(`.agents/skills/oversample-tests/SKILL.md`) for the exact run commands,
Lua 5.1/LuaJIT caveats, test targets, the passing baseline, and the Renoise
visual-check steps. The Lua syntax check there is also a commit gate.

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
