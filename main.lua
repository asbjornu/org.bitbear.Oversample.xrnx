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

local options = renoise.Document.create("preferences") {
  debug = true
}

--------------------------------------------------------------------------------
-- Menu entries
--------------------------------------------------------------------------------

renoise.tool().preferences = options
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Oversample",
  invoke = oversample
}
