# Oversample

![Build][build-badge]
![License][license-badge]
![Renoise API][renoise-api-badge]
![Lua][lua-badge]
![codecov][coverage-badge]


Oversample is a [Renoise][renoise] plugin that lets you push the quality
parameters (such as "oversampling", "quality", "phase", etc.) of the devices in
your song to their extremes, so you get the best quality when rendering a song
to WAV, and then pull them back down again so you don't melt your CPU while
producing.

## Quick start

1. Open **Tools > Oversample** in Renoise.
2. Choose the target values, or use **Minimize** / **Maximize** to preview the
   available extremes in the controls.
3. Click **Set** to apply the targets to the devices in your song.

After updating the installed tool, use **Tools > Reload all tools**, then reopen
Oversample. Keep a backup of your song before applying changes.

## How it works

The tool opens a dialog with a grid of *device/parameter rows*. Each row targets
the active instances of a device name in the song and one (or two) of its quality
settings, rather than one individual plugin instance:

* Recognised devices get rows automatically, with fixed, right-aligned labels
  for their known quality parameters.
* Use **+** to add rows. For unrecognised devices, the tool scans exposed host
  parameters and lets you select one from a dropdown. Known devices retain their
  fixed quality parameter rather than offering arbitrary parameter selection.
* **Minimize** and **Maximize** are *preview-only*: they select minimum/maximum
  targets in the controls without applying those targets to the plugins.
  **Set** applies the current targets to the actual devices.

### FabFilter VST3 support

The supported FabFilter VST3 plugins do not expose oversampling as a host
parameter. Oversample instead patches known byte positions in the plugin state
chunk embedded in Renoise's preset XML. Built-in signatures cover **Pro-Q 3**,
**Pro-C 2**, **Pro-L 2**, **Pro-MB**, and **Saturn 2**. Other plugin formats can
use exposed host parameters where available.

Saturn 2 has two independent controls: **High Quality** (Off / Good / Superb)
and **Linear Phase** (Off / On). Linear Phase remains available even when High
Quality is Off.

**Saving side effect:** before applying a state-chunk target, Set attempts to
save a song that already has a filename, to refresh Renoise's cached plugin
state. This also saves any other pending song changes. Songs without a filename
skip this step without opening a save dialog. The save is before patching, not
a guarantee that all newly applied targets have been saved; save again afterward
if you want to persist them.

### Caching

Enumerating plugin parameters can be slow, so Oversample caches parameter lists
and device names:

* A **per-song cache** is stored inside the song file via
  `renoise.song().tool_data`. It travels with the `.xrns` and overrides the
  machine-wide parameter cache, reducing repeat scans when reopening a song.
* A **machine-wide cache** is stored in the tool's `preferences.xml` and survives
  across songs and sessions.

Caches are populated lazily and refreshed or invalidated as devices and presets
change. Reopening is usually faster, but new or changed devices may still need
scanning. Known VST3 signatures avoid enumerating quality parameters that the
plugin does not expose.

## Known limitations

* Only FabFilter plugins are recognised automatically. Manual parameter selection
  for other plugins is limited to parameters exposed to Renoise; it cannot expose
  an otherwise hidden quality setting.
* State-chunk signatures depend on the plugin's serialized format. Plugin updates
  may require new signatures; version compatibility is not automatically verified.
  Check the resulting settings in the plugin, especially after an update.
* Chunk patching is intended to change only the selected quality settings, but
  stale cached state or an incompatible signature can affect other settings.
  Unsaved songs skip the state-refresh save, and a failed save does not stop
  patching. Keep backups rather than relying on unrelated settings being preserved.
* Avoid duplicate rows for the same target. Set applies rows in order, so later
  rows can overwrite earlier targets; duplicates are not guaranteed to be harmless.

## Disclaimer

**Oversample started as a young and immature extension made to support my own
needs and may still not work for you.**

* I learnt Lua as well as Renoise Extension development while developing Oversample,
  so be careful and gentle. Save the song before attempting to use the plugin and
  keep backups.

## Testing & coverage

The pure, Renoise-independent logic lives in `Oversample/oversample_core.lua` and
is unit-tested with [luaunit][luaunit] in `test/oversample_core_test.lua`, which
runs in CI via the Test workflow under [luacov][luacov]. Core coverage is reported
to [Codecov][codecov].

`test/oversample_ui_test.lua` uses a small ViewBuilder stub to check footer sizing,
fixed status dimensions, secondary visibility, control switching, and add-button
placement. It exercises the actual dialog code but does not emulate native text
metrics, clipping, rendering, or notifier timing. After UI changes, reload the
tool in Renoise and visually check the dialog as well.

Run both suites from the tool root after installing the rockspec dependencies:

```sh
eval "$(luarocks path)"
lua test/oversample_core_test.lua
lua test/oversample_ui_test.lua
```

CI runs both suites with Lua 5.1 and LuaJIT. UI stub tests are excluded from the
coverage report, so the badge continues to reflect only the core module.

  [renoise]: https://www.renoise.com/
  [luaunit]: https://github.com/bluebird75/luaUnit
  [luacov]: https://keplerproject.github.io/luacov/
  [codecov]: https://codecov.io/gh/asbjornu/org.bitbear.Oversample.xrnx
  [build-badge]: https://github.com/asbjornu/org.bitbear.Oversample.xrnx/actions/workflows/build.yml/badge.svg
  [license-badge]: https://img.shields.io/github/license/asbjornu/org.bitbear.Oversample.xrnx
  [renoise-api-badge]: https://img.shields.io/badge/Renoise%20API-6-blue
  [lua-badge]: https://img.shields.io/badge/Lua-5.1-blue
  [coverage-badge]: https://codecov.io/gh/asbjornu/org.bitbear.Oversample.xrnx/branch/main/graph/badge.svg
