--[[============================================================================
org.bitbear.Oversample.xrnx/main.lua

Written by Bitbear
https://bitbear.org/
============================================================================]]--

require "Oversample/Oversample"
require "Oversample/ProcessSlicer"

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
  cached_device_names = renoise.Document.ObservableStringList()
}

--------------------------------------------------------------------------------
-- Menu entries
--------------------------------------------------------------------------------

renoise.tool().preferences = options

oversample_init()
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Oversample",
  invoke = oversample
}
