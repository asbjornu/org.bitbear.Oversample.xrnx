function oversample()
  local vb = renoise.ViewBuilder()

  local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
  local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
  local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
  local COLUMN_WIDTH = 8 * renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT

  local knownDevices = {
    "FabFilter: Pro-MB"
  }

  local knownParameters = {
    "Oversampling",
    "Processing Mode",
    "Processing Resolution"
  }

  local layout = vb:row {
    margin = CONTENT_MARGIN
  }

  local knownDevicesRow = vb:row {
    margin = DEFAULT_DIALOG_MARGIN,
    spacing = DEFAULT_CONTROL_SPACING,

    vb:text {
      id = "knownDevices",
      text = "Known devices"
    },
  }

  for t = 1, table.getn(renoise.song().tracks) do
    local track = renoise.song().tracks[t]
    local trackColumn = vb:column {
      vb:text {
        text = track.name,
        width = COLUMN_WIDTH
      }
    }

    -- print(track.name)

    for d = 1, table.getn(track.devices) do
      local device = track.devices[d]

      trackColumn:add_child(vb:text {
        text = device.name
      })

      -- octave_row:add_child(note_button)

      -- print(("    %s (%s)"):format(device.name, device.device_path))

      if (device.is_active) then
        for p = 1, table.getn(device.parameters) do
          local parameter = device.parameters[p]

          --[[

          print(("        %s: %d, min(%d), $max(%d), quantum(%d), default(%d)."):format(
            parameter.name,
            parameter.value,
            parameter.value_min,
            parameter.value_max,
            parameter.value_quantum,
            parameter.value_default
          ))

          -- parameter.record_value(value)
          ]]--

        end
      end
    end

    layout:add_child(trackColumn)
  end

  --[[
  local NUM_OCTAVES = 10
  local NUM_NOTES = 12

  for octave = 1,NUM_OCTAVES do
    -- create a row for each octave
    local octave_row = vb:row {}

    for note = 1,NUM_NOTES do
      local note_button = vb:button {
        width = BUTTON_WIDTH,
        text = note_strings[note]..tostring(octave - 1),

        notifier = function()
          -- functions do memorize all values in the scope they are
          -- nested in (upvalues), so we can simply access the note and
          -- octave from the loop here:
          show_status(("note_button %s%d got pressed"):format(
            note_strings[note], octave - 1))
        end

      }
      -- add the button by "hand" into the octave_row
      octave_row:add_child(note_button)
    end

    layout:add_child(octave_row)
  end

  ]]--

  renoise.app():show_custom_dialog("Batch Building Views", layout, {"OK"})
end
