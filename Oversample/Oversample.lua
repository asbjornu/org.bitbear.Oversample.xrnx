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

    print('oversample:ProcessSlicer:init')
    local slicer = ProcessSlicer(enumerate_tracks, nil, layout)

    print('oversample:ProcessSlicer:start')
    slicer:start()

    print('oversample:Renoise:show_custom_dialog')
    dialog = renoise.app():show_custom_dialog("Batch Building Views", layout)

    -- print('oversample:ProcessSlicer:stop')
    -- slicer:stop()
end

function enumerate_tracks(layout)
    print('enumerate_tracks')
    
    local song = renoise.song()

    for t = 1, table.getn(song.tracks) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local track = song:track(t)

        print(track.name)

        local trackColumn = vb:column {
            margin = DEFAULT_DIALOG_MARGIN,
            vb:text {
                text = track.name,
                width = COLUMN_WIDTH
            }
        }

        print('enumerate_tracks:ProcessSlicer:init')
        local slicer = ProcessSlicer(enumerate_devices, nil, track, trackColumn)
        
        print('enumerate_tracks:ProcessSlicer:start')        
        slicer:start()
    
        coroutine.yield()
        layout:add_child(trackColumn)
    end
end

function enumerate_devices(track, trackColumn)
    for d = 1, table.getn(track.devices) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local device = track:device(d)

        print(("    %s (%s)"):format(device.name, device.device_path))

        trackColumn:add_child(vb:text {
            text = device.name
        })

        if (device.is_active) then
            print('enumerate_devices:ProcessSlicer:init')
            local slicer = ProcessSlicer(enumerate_parameters, nil, device)
            
            print('enumerate_devices:ProcessSlicer:start')        
            slicer:start()   
        end

        coroutine.yield()
    end
end

function enumerate_parameters(device)
    for p = 1, table.getn(device.parameters) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local parameter = device:parameter(p)

        print(("        %s: %d, min(%d), $max(%d), quantum(%d), default(%d)."):format(
            parameter.name,
            parameter.value,
            parameter.value_min,
            parameter.value_max,
            parameter.value_quantum,
            parameter.value_default
        ))

        -- parameter.record_value(value)

        coroutine.yield()
    end
end

function done_oversampling()
end
