--[[============================================================================
nu.asbjor.Oversample.xrnx/main.lua
============================================================================]]--

--------------------------------------------------------------------------------
-- preferences
--------------------------------------------------------------------------------

local options = renoise.Document.create("RnsGitPreferences") {
  debug = true
}

renoise.tool().preferences = options

renoise.tool().app_became_active_observable:add_notifier(function()
  if (options.debug.value) then
    print('nu.asbjor.Oversample: Active!')
  end

  local vb = renoise.ViewBuilder() -- create a new ViewBuilder
  local button = vb:button { text = "ButtonText" } -- is the same as
  local dialog_title = "Hello World"

  local dialog_content = vb:text {
    text = "from the Renoise Scripting API"
  }

  local dialog_buttons = {"OK"}
  renoise.app():show_custom_prompt(
    dialog_title, dialog_content, dialog_buttons)
end)

-- Invoked each time a new document (song) was created or loaded.
renoise.tool().app_new_document_observable:add_notifier(function()
  handle_app_new_document_notification()
end)


--[[
-- Devices.

renoise.song().tracks[].available_devices[]
  -> [read-only, array of strings]

-- Returns a list of tables containing more information about the devices. 
-- Each table has the following fields:
--  {
--    path,           -- The device's path used by insert_device_at()
--    name,           -- The device's name
--    short_name,     -- The device's name as displayed in shortened lists
--    favorite_name,  -- The device's name as displayed in favorites
--    is_favorite,    -- true if the device is a favorite
--    is_bridged      -- true if the device is a bridged plugin
--  }
renoise.song().tracks[].available_device_infos[]
  -> [read-only, array of strings]

renoise.song().tracks[].devices[], _observable
  -> [read-only, array of renoise.AudioDevice objects]

--------------------------------------------------------------------------------
-- renoise.GroupTrack (inherits from renoise.Track)
--------------------------------------------------------------------------------

-------- Functions

-- All member tracks of this group (including subgroups and their tracks).
renoise.song().tracks[].members[]
  -> [read-only, array of member tracks]

-- Collapsed/expanded visual appearance of whole group.
renoise.song().tracks[].group_collapsed
  -> [boolean]



]]--


-- Invoked each time the apps document (song) was successfully saved.
renoise.tool().app_saved_document_observable:add_notifier(function()
  handle_app_saved_document_notification()
end)


-- handle_app_new_document_notification
function handle_app_new_document_notification()
  if (options.debug.value) then
    print(("com.renoise.Oversample: !! app_new_document "..
      "notification (filename: '%s')"):format(renoise.song().file_name))
  end
end


-- handle_app_saved_document_notification
function handle_app_saved_document_notification()
  if (options.debug.value) then
    print(("com.renoise.Oversample: !! handle_app_saved_document "..
      "notification (filename: '%s')"):format(renoise.song().file_name))
  end
end