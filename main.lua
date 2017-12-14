--[[============================================================================
org.bitbear.Oversample.xrnx/main.lua

Written by Bitbear
https://bitbear.org/
============================================================================]]--

require "Oversample/Oversample"

--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

local options = renoise.Document.create("org.bitbear.Oversample.Preferences") {
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
