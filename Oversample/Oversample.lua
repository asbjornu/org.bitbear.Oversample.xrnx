local vb = renoise.ViewBuilder()
local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
local COLUMN_WIDTH = 8 * renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT
local oversample_dialog = nil
local settings_dialog = nil
local settings_layout = nil
local devices = {}

function oversample()
    local layout = vb:row {
        margin = CONTENT_MARGIN
    }

    local oversample_column = vb:column {
        margin = DEFAULT_DIALOG_MARGIN,
        vb:button {
            text = "Oversample",
            width = COLUMN_WIDTH
        }
    }
    
    oversample_column:add_child(vb:button {
        text = "Settings",
        width = COLUMN_WIDTH,
        notifier = settings
    })
    
    layout:add_child(oversample_column)

    oversample_dialog = renoise.app():show_custom_dialog("Oversample", layout)
end

function settings()
    settings_layout = vb:row {
        margin = CONTENT_MARGIN
    }

    print('oversample:ProcessSlicer:init')
    local slicer = ProcessSlicer(enumerate_tracks, add_device_popup)

    print('oversample:ProcessSlicer:start')
    slicer:start()

    print('oversample:Renoise:show_custom_dialog')
    settings_dialog = renoise.app():show_custom_dialog("Oversample settings", settings_layout)

    -- print('oversample:ProcessSlicer:stop')
    -- slicer:stop()
end

function add_device_popup()
    print('add_device_popup')
    local device_items = {}

    local i = 1
    for k, v in pairs(devices) do
        device_items[i] = k
        i = i + 1
    end

    local devices_popup = vb:popup {
        items = device_items,
        value = 1,
        width = COLUMN_WIDTH,
        notifier = function(value)
            local device_name = device_items[value]
            print(device_name)
        end,
    }

    local devices_view = vb:horizontal_aligner {
        mode = "justify",
        vb:text {
            text = "Device:"
        },
        devices_popup
    }

    settings_layout:add_child(devices_view)
end

function enumerate_tracks()
    print('enumerate_tracks')
    
    local song = renoise.song()

    for t = 1, table.getn(song.tracks) do
        if (settings_dialog and not settings_dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local track = song:track(t)

        -- print(track.name)

        -- print('enumerate_tracks:ProcessSlicer:init')
        local slicer = ProcessSlicer(enumerate_devices, nil, track)
        
        -- print('enumerate_tracks:ProcessSlicer:start')        
        slicer:start()
    
        coroutine.yield()
    end
end

function enumerate_devices(track)
    for d = 1, table.getn(track.devices) do
        if (settings_dialog and not settings_dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local device = track:device(d)

        if (device.is_active and not devices[device.name]) then
            devices[device.name] = device.name
            --[[
            print('enumerate_devices:ProcessSlicer:init')
            local slicer = ProcessSlicer(enumerate_parameters, nil, device)
            
            print('enumerate_devices:ProcessSlicer:start')        
            slicer:start()   
            ]]--
        end

        coroutine.yield()
    end
end

function enumerate_parameters(device)
    devices[device.name] = {}

    for p = 1, table.getn(device.parameters) do
        if (settings_dialog and not settings_dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local parameter = device:parameter(p)

        devices[device.name][parameter.name] = parameter.value

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
