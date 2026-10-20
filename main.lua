--[[============================================================================
org.bitbear.Oversample.xrnx/main.lua

Written by Bitbear
https://bitbear.org/
============================================================================]]--

-- Put the bundle root and lib/ on the Lua module path so the tool's own modules
-- (under lib/) and vendored files load. `bundle_path` is the installed tool dir.
local tool_bundle = renoise.tool().bundle_path
package.path = tool_bundle .. "/?.lua;"
            .. tool_bundle .. "/lib/?.lua;"
            .. package.path

local Oversample = require "oversample/oversample"
require "ProcessSlicer"

--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

-- 'cached_parameters' is a machine-wide, persistent cache of plugin parameter
-- lists (survives across songs and sessions, stored in the tool's
-- preferences.xml). Once a plugin type's parameters are known, the tool never
-- has to reach into the installed plugin again to list them.
local options = renoise.Document.create("preferences") {
  debug = true,
  cached_parameters = renoise.Document.ObservableStringList(),
  cached_device_names = renoise.Document.ObservableStringList(),
  osig = renoise.Document.ObservableStringList()
}

--------------------------------------------------------------------------------
-- Menu entries
--------------------------------------------------------------------------------

renoise.tool().preferences = options

Oversample.oversample_init()
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Oversample",
  invoke = Oversample.oversample
}
