local vb = renoise.ViewBuilder()
local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
local COLUMN_WIDTH = 16 * renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT
local settings_dialog = nil
local devices = {}

function oversample()
    renoise.app():show_custom_dialog("Oversample", vb:row {
        margin = CONTENT_MARGIN,
        vb:column {
            margin = DEFAULT_DIALOG_MARGIN,
            vb:button {
                text = "Oversample",
                width = COLUMN_WIDTH
            },
            vb:button {
                text = "Settings",
                width = COLUMN_WIDTH,
                notifier = settings
            }
        }
    })
end

function settings()
    -- print('oversample:ProcessSlicer:init')
    local slicer = ProcessSlicer(enumerate_tracks, add_device_popup)

    -- print('oversample:ProcessSlicer:start')
    slicer:start()

    -- print('oversample:Renoise:show_custom_dialog')
    settings_dialog = renoise.app():show_custom_dialog("Oversample settings", vb:row {
        margin = CONTENT_MARGIN,
        vb:column {
            vb:row {
                vb:column {
                    vb:text {
                        text = "Device",
                        width = COLUMN_WIDTH
                    },
                    vb:popup {
                        id = "devices_popup",
                        width = COLUMN_WIDTH,
                        notifier = function(value)
                            local device_name = vb.views.devices_popup.items[value]
                            device_selected(device_name)
                        end,
                    },
                },
                vb:column {
                    vb:text {
                        text = "Parameters",
                        width = COLUMN_WIDTH
                    },
                    vb:popup {
                        id = "parameters_popup",
                        width = COLUMN_WIDTH,
                        notifier = function(value)
                            local parameter_name = vb.views.parameters_popup.items[value]
                            print(parameter_name)
                        end,
                    }
                }
            },
            vb:text {
                id = "status",
                text = "Finding devices...",
                width = COLUMN_WIDTH
            }
        }
    })

    -- print('oversample:ProcessSlicer:stop')
    -- slicer:stop()
end

function add_device_popup()
    -- print('add_device_popup')
    local device_items = {}

    local i = 1
    for k, v in pairs(devices) do
        device_items[i] = k
        i = i + 1
    end

    vb.views.status.text = 'Done.'
    vb.views.devices_popup.items = device_items
end

function device_selected(device_name)
    -- print('device_selected')
    local device = devices[device_name]

    local slicer = ProcessSlicer(enumerate_parameters, function(return_value)
        -- print('device_selected:parameters_enumerated')
        -- Unpack the return value table; the first value is the parameters returned by enumerate_parameters
        local parameters = return_value[1]
        local parameter_items = {}

        local i = 1
        for k, v in pairs(parameters) do
            print(v)
            parameter_items[i] = k
            i = i + 1
        end

        rprint(parameter_items)
    
        vb.views.status.text = 'Done.'
        vb.views.parameters_popup.items = parameter_items
    end, device)

    -- print('enumerate_devices:ProcessSlicer:start')        
    slicer:start()   
end

function enumerate_tracks()
    -- print('enumerate_tracks')
    
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
            vb.views.status.text = track.name .. ': ' .. device.name
            devices[device.name] = device
        end

        coroutine.yield()
    end
end

function enumerate_parameters(device)
    print('enumerate_parameters')
        
    --[[ TODO: Figure out how to extract parameters from cache.
    if (devices[device.name] ~= nil and type(devices[device.name]) == "table") then
        return devices[device.name]
    end
    --]]

    local parameters = {}

    for p = 1, table.getn(device.parameters) do
        if (settings_dialog and not settings_dialog.visible) then
            print('Dialog closed, stopping.')
            return parameters
        end

        local parameter = device:parameter(p)

        vb.views.status.text = device.name .. ': ' .. parameter.name
        parameters[parameter.name] = parameter.value

        --[[
        print(("        %s: %d, min(%d), $max(%d), quantum(%d), default(%d)."):format(
            parameter.name,
            parameter.value,
            parameter.value_min,
            parameter.value_max,
            parameter.value_quantum,
            parameter.value_default
        ))
        ]]--

        -- parameter.record_value(value)

        coroutine.yield()
    end

    -- rprint(parameters)

    devices[device.name] = parameters
    return parameters
end

function done_oversampling()
end
