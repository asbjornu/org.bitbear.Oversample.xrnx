# Oversample

![Build][build-badge]
![License][license-badge]
![Renoise API][renoise-api-badge]
![Lua][lua-badge]
![Coverage (core)][coverage-badge]


Oversample is a [Renoise][renoise] plugin that will increase all quality
parameters (such as "oversampling", "quality", "phase", etc.) in all active
devices in the song to maximum, so you get the best quality when rendering a
song to WAV.

When rendering is done, Oversample will allow you to turn all quality
parameters back down to minimum ("Undersample") to not destroy your CPU while
producing.

## Disclaimer

**Oversample is a very young and immature extension made to support my own
needs and may not work for you.**

## Known defects and missing features:

* There's no disk-based caching, so the first time Oversample is loaded, it's going
  to take a while.
* Oversample currently only knows about FabFilter plugins with quality parameters,
  so only those will be added if present in the song.
* It's possible to add a quality parameter as many times as you want. Every time a
  parameter is added, it should be removed from all other popups, preferably.
* I learnt Lua as well as Renoise Extension development while developing Oversample,
  so be careful and gentle. Save the song before attempting to use the plugin and
  keep backups.

## Testing & coverage

The pure, Renoise-independent logic lives in `Oversample/oversample_core.lua` and
is unit-tested with [luaunit][luaunit] in `test/oversample_core_test.lua`, which
runs in CI via the Test workflow under [luacov][luacov]. Every public function of
that core module is exercised by the suite, and its line coverage is measured by
luacov in CI and shown in the badge above (the few untested lines are defensive
branches for an unused data shape).

`Oversample/Oversample.lua` and `main.lua` are coupled to the Renoise runtime (the
`renoise` global and `ViewBuilder`) and cannot run outside of Renoise, so they are
intentionally excluded from unit testing. The "Coverage (core)" badge therefore
reflects only the testable core module, not the whole tool.

  [renoise]: https://www.renoise.com/
  [luaunit]: https://github.com/bluebird75/luaUnit
  [luacov]: https://keplerproject.github.io/luacov/
  [build-badge]: https://github.com/asbjornu/org.bitbear.Oversample.xrnx/actions/workflows/build.yml/badge.svg
  [license-badge]: https://img.shields.io/github/license/asbjornu/org.bitbear.Oversample.xrnx
  [renoise-api-badge]: https://img.shields.io/badge/Renoise%20API-6-blue
  [lua-badge]: https://img.shields.io/badge/Lua-5.1-blue
  [coverage-badge]: https://img.shields.io/badge/coverage%20(core)-97.66%25-brightgreen
