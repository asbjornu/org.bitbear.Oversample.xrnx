--[[============================================================================
org.bitbear.Oversample.xrnx/main.lua
============================================================================]]--

--------------------------------------------------------------------------------
-- preferences
--------------------------------------------------------------------------------

local options = renoise.Document.create("RnsGitPreferences") {
  debug = true
}

renoise.tool().preferences = options
renoise.tool():add_menu_entry {
  name = "Main Menu:Tools:Oversample",
  invoke = function() oversample() end 
}

function oversample()

  -- beside of "stacking" views in columns and rows, its sometimes also useful
  -- to align some parts of the views for example centered or right
  -- this is what the view builders "horizontal_aligner" and "vertical_aligner"
  -- building blocks are for.
  
  -- related to this topic, we'll also show how you can auto size views: (size
  -- a view relative to its parents size). This is done by simply specifying
  -- percentage values for the sizes, like: width = "100%"

  local vb = renoise.ViewBuilder()

  local DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
  local CONTENT_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING

  -- lets create a simple dialog as usual, and align a few totally useless
  -- buttons & texts:
  local dialog_content = vb:column {
    id = "dialog_content",
    margin = DIALOG_MARGIN,
    spacing = CONTENT_SPACING,
    
    -- first center a text. We don't necessarily need aligners for this, 
    -- but simply resize the text to fill the entrire row in the column, 
    -- then tell the text view how it should align its content:
    vb:text {
      text = "horizontal_aligner",
      width = "100%",
      align = "center",
      font = "bold"
    },
    
    -- add a large Textfield (this will be our largest view the other 
    -- views will align to)
    vb:textfield {
      value = "Large Text field",
      width = 300
    },
    
    -- align a text to the right, using 'align_horizontal'
    -- aligners do have margins & spacings, just like columns, rows have, which
    -- we now use to place a text 20 pixels on the right, top, bottom:
    vb:horizontal_aligner {
      mode = "right",
      margin = 20,

      vb:text {
        text = "I'm right and margined",
      },
    },
    
    -- align a set of buttons to the left, using 'align_horizontal'
    -- well, this is actually just what "row" does, but horizontal_aligner 
    -- automatically uses a width of "100%", while you can not use a "row"
    -- with a relative width...
    vb:horizontal_aligner {
      mode = "left",

      vb:button {
        text = "[",
        width = 40
      },
      vb:button {
        text = "Left",
        width = 80
      },
      vb:button {
        text = "]",
        width = 20
      }
    },
    
    -- align a set of buttons to the right, using 'align_horizontal'
    vb:horizontal_aligner {
      mode = "right",

      vb:button {
        text = "[",
        width = 40
      },
      vb:button {
        text = "Right",
        width = 80
      },
      vb:button {
        text = "]",
        width = 20
      }
    },
    
    -- align a set of buttons centered, using 'align_horizontal'
    vb:horizontal_aligner {
      mode = "center",

      vb:button {
        text = "Center",
        width = 80
      }
    },
    
    -- again a set of buttons centered, but with some spacing
    vb:horizontal_aligner {
      mode = "center",
      spacing = 8,

       vb:button {
        text = "[",
        width = 40
      },
      vb:button {
        text = "Spacing = 8",
        width = 80
      },
      vb:button {
        text = "]",
        width = 20
      }
    },
    
    -- show the "justify" align style
    vb:horizontal_aligner {
      mode = "justify",
      spacing = 8,

       vb:button {
        text = "[",
        width = 40
      },
      vb:button {
        text = "Justify",
        width = 80
      },
      vb:button {
        text = "]",
        width = 20
      }
    },
    
    -- show the "distribute" align style
    vb:horizontal_aligner {
      mode = "distribute",
      spacing = 8,

       vb:button {
        text = "[",
        width = 40
      },
      vb:button {
        text = "Distribute",
        width = 80
      },
      vb:button {
        text = "]",
        width = 20
      }
    },
    

    -- add a space before we start with a "new category"
    vb:space {
      height = 20
    },
    
    -- lets use/show relative width, height properties:
    vb:text {
      text = "relative sizes",
      font = "bold",
      width = "100%",
      align = "center"
    },
    
    
    -- create a aligner again, but this time just to stack
    -- some views:
    vb:horizontal_aligner {
      width = "100%",
      
      vb:button {
        text = "20%",
        width = "20%"
      },
      vb:button {
        text = "80%",
        width = "80%"
      },
    },
    

    -- again a space before we start with a "new category"
    vb:space {
      height = 20
    },
    
    -- not lets create a button that toggles another view. when toggling, we 
    -- do update the main racks size which also updates the dialogs size: 
    vb:text {
      text = "resize racks & dialogs",
      width = "100%",
      align = "center",
      font = "bold"
    },
    
    -- add a button that hides the other view:
    vb:button {
      text = "Click me",
      notifier = function()
        -- toggle visibility of the view on each click
        vb.views.hide_me_text.visible = not vb.views.hide_me_text.visible

        -- and update the main content view size and thus also the dialog size
        vb.views.dialog_content:resize()
      end,
    },

    -- the text view that we are going to show/hide
    vb:text {
      id = "hide_me_text",
      text = "Click the button above to hide this view",
    },
  }
  
 renoise.app():show_custom_dialog(
    "Aligning & Auto Sizing", dialog_content)
end


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