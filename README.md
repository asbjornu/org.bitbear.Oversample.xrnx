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

## How it works

The tool opens a dialog with a grid of *device/parameter rows*. Each row targets
one device in the song and one (or two) of its parameters that affect quality:

* When the tool is opened it automatically adds a row for every recognised
  device it finds in the song (see *Known limitations* below for which devices
  are recognised out of the box), and scans that device's parameters in the
  background so the full parameter list is available in the row's dropdowns.
* You can add more rows manually, and for any row you can pick *any* device and
  *any* parameter — recognised or not — so the tool is not limited to the built-in
  device list.
* **Minimize** and **Maximize** are *preview-only*: they snap the row sliders to
  the minimum/maximum values so you can eyeball the effect, but don't touch your
  song. **Set** applies the current slider state to the actual devices. This way
  you can dial in exactly which parameters go to min/max and which stay put
  before committing.

Only the recognised oversampling parameters (plus each row's selected parameters)
are ever driven — never every parameter of a device — so unrelated settings are
left alone.

### Caching

Enumerating every parameter of every plugin is what used to make the tool slow.
Parameter lists only change when a plugin is added, removed, or its preset
changes, so Oversample caches them:

* A **per-song cache** is stored inside the song file via
  `renoise.song().tool_data`. It travels with the `.xrns` and overrides the
  machine-wide cache, so reopening a song is instant.
* A **machine-wide cache** is stored in the tool's `preferences.xml` and survives
  across songs and sessions.

Both caches are populated lazily as devices are scanned, and invalidated
automatically when a plugin is added/removed or its preset changes. The first
time you open a brand-new song with many plugins it still takes a moment to scan
them, but afterwards it's instant.

## Known limitations

* Only FabFilter plugins are *recognised automatically* (and only their quality
  parameters are preselected). For other plugins you can still target any
  parameter manually via a row's dropdowns — auto-recognition is just a
  convenience.
* Adding more rows than necessary is harmless: when **Set**, **Minimize** or
  **Maximize** is applied, each targeted device parameter is de-duplicated, so a
  parameter can only be driven once even if it appears in several rows.

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
