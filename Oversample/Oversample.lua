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

local dialog = nil

function oversample()
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

    print('ProcessSlicer:init')

    local slicer = ProcessSlicer(do_oversample, nil, layout)

    print('ProcessSlicer:start')
    slicer:start()

    print('Renoise:show_custom_dialog')
    dialog = renoise.app():show_custom_dialog("Batch Building Views", layout)

    -- print('ProcessSlicer:stop')
    -- slicer:stop()
end

function do_oversample(layout)
    print('do_oversample')

    for t = 1, #renoise.song().tracks do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local track = renoise.song().tracks[t]

        -- print(track.name)

        local trackColumn = vb:column {
            margin = DEFAULT_DIALOG_MARGIN,
            vb:text {
                text = track.name,
                width = COLUMN_WIDTH
            }
        }

        for d = 1, #track.devices do
            if (dialog and not dialog.visible) then
                print('Dialog closed, stopping.')
                return
            end

            local device = track.devices[d]

            -- print(("    %s (%s)"):format(device.name, device.device_path))

            trackColumn:add_child(vb:text {
                text = device.name
            })

            if (device.is_active) then
                local parameters = device.parameters
                for p = 1, #parameters do
                    if (dialog and not dialog.visible) then
                        print('Dialog closed, stopping.')
                        return
                    end

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

                    coroutine.yield()
                end
            end

            coroutine.yield()
        end

        layout:add_child(trackColumn)
    end
end

function done_oversampling()
end
