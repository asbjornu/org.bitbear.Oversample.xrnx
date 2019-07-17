# Oversample

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

  [renoise]: https://www.renoise.com/