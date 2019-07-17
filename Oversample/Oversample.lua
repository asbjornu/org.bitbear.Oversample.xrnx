local vb = renoise.ViewBuilder()
local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
local CONTENT_HEIGHT = renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT
local COLUMN_WIDTH = 16 * CONTENT_HEIGHT
local dialog = nil
local devices = {}
local settings_row_count = 0
local device_popups = {}
local known_devices_parameters = {
     ['VST: FabFilter: Saturn'] = 'High Quality',
     ['VST: FabFilter: Pro-MB'] = 'Oversampling',
     ['VST: FabFilter: Pro-C 2'] = 'Oversampling',
     ['VST: FabFilter: Pro-L 2'] = 'Oversampling',
     ['VST: FabFilter: Pro-Q 2'] = {
        'Processing Mode', 'Processing Resolution'
     },
}

function oversample()
    -- print('oversample:ProcessSlicer:init')
    local slicer = ProcessSlicer(enumerate_tracks, add_device_items_init)

    -- print('oversample:ProcessSlicer:start')
    slicer:start()

    -- print('oversample:Renoise:show_custom_dialog')

    renoise.app():show_custom_dialog("Oversample", vb:row {
        margin = CONTENT_MARGIN,
        vb:column {
            vb:row {
                vb:text {
                    text = "Device",
                    width = COLUMN_WIDTH
                },
                vb:text {
                    text = "Parameters",
                    width = COLUMN_WIDTH
                },
                vb:space {
                    width = 16,
                    height = CONTENT_HEIGHT
                },
            },
            vb:column {
                id = "settings_container"
            },
            vb:space {
                height = CONTENT_HEIGHT
            },
            vb:horizontal_aligner {
                mode = "justify",
                vb:text {
                    id = "status",
                    text = "Finding devices...",
                    width = COLUMN_WIDTH
                },
                vb:button {
                    text = "Oversample",
                    width = 100,
                    notifier = do_oversample()
                }
            }
        },
    })
end

function create_settings_row()
    local prev_settings_row_identifiers = create_settings_row_identifiers()

    local add_button = vb.views[prev_settings_row_identifiers["add_button_id"]]
    local settings_row = vb.views[prev_settings_row_identifiers["settings_row_id"]]
    if (settings_row and add_button) then
        settings_row:remove_child(add_button)
    end

    settings_row_count = settings_row_count + 1
    local settings_row_identifiers = create_settings_row_identifiers()

    local devices_popup_id = settings_row_identifiers["devices_popup_id"]
    local parameters_popup_id = settings_row_identifiers["parameters_popup_id"]
    local settings_row_id = settings_row_identifiers["settings_row_id"]
    local add_button_id = settings_row_identifiers["add_button_id"]

    device_popups[settings_row_count] = devices_popup_id

    return vb:row {
        id = settings_row_id,
        vb:popup {
            id = devices_popup_id,
            width = COLUMN_WIDTH,
            notifier = function(value)
                local device_name = vb.views[devices_popup_id].items[value]
                device_selected(device_name, parameters_popup_id)
            end,
        },
        vb:popup {
            id = parameters_popup_id,
            width = COLUMN_WIDTH,
            notifier = function(value)
                local parameter_name = vb.views[parameters_popup_id].items[value]
                local selected_device_index = vb.views[devices_popup_id].value
                local device_name = vb.views[devices_popup_id].items[selected_device_index]
                parameter_selected(value, parameter_name, device_name)
            end,
        },
        vb:button {
            id = add_button_id,
            text = "+",
            width = 16,
            notifier = function()
                local settings_row = create_settings_row()
                vb.views.settings_container:add_child(settings_row)
            end,
        }
    }
end

function create_settings_row_identifiers()    
    return {
        ["devices_popup_id"] = "devices_popup_" .. settings_row_count,
        ["parameters_popup_id"] = "parameters_popup_" .. settings_row_count,
        ["settings_row_id"] = "settings_row_" .. settings_row_count,
        ["add_button_id"] = "add_button_" .. settings_row_count
    }
end

function add_device_items_init()
    local device_items = {}

    local i = 1
    for k, v in pairs(devices) do
        device_items[i] = k
        i = i + 1
    end

    local found = false
    for device_index, device_name in ipairs(device_items) do
        for known_device_name, _ in pairs(known_devices_parameters) do
            if (known_device_name == device_name) then
                found = true
                -- print('Found known device "' .. device_name .. '", adding popup for it with preselected value.')
                local settings_row = create_settings_row()
                vb.views.settings_container:add_child(settings_row)
                local settings_row_identifiers = create_settings_row_identifiers()
                local devices_popup_id = settings_row_identifiers["devices_popup_id"]
                add_device_items(devices_popup_id, device_index)
            else
                -- print('Unknown device "' .. device_name .. '", skipping')
            end
        end
    end

    if (not found) then
        local settings_row = create_settings_row()
        vb.views.settings_container:add_child(settings_row)
    end

    for i, v in ipairs(device_popups) do
        vb.views[v].items = device_items
    end

    vb.views.status.text = 'Done.'
end

function add_device_items(devices_popup_id, selected_device_index)
    local device_items = {}

    local i = 1
    for k, v in pairs(devices) do
        device_items[i] = k
        i = i + 1
    end

    if (vb.views[devices_popup_id]) then
        local devices_popup = vb.views[devices_popup_id]
        devices_popup.items = device_items
        devices_popup.value = selected_device_index
    else
        print('Could not add items to "' .. devices_popup_id .. '" as it does not exist.')
    end

    vb.views.status.text = 'Done.'
end

function device_selected(device_name, parameters_popup_id)
    -- print('device_selected')

    local slicer = ProcessSlicer(enumerate_parameters, function(return_value)
        -- print('device_selected:parameters_enumerated')
        -- Unpack the return value table; the first value is the parameters returned by enumerate_parameters
        local parameters = return_value[1]

        -- rprint(parameters)
    
        vb.views.status.text = 'Done.'
        vb.views[parameters_popup_id].items = parameters
    end, device_name)

    -- print('enumerate_devices:ProcessSlicer:start')        
    slicer:start()   
end

function parameter_selected(parameter_index, parameter_name, device_name)
    print(device_name)
    local device_instances = devices[device_name]["instances"]

    for k, v in ipairs(device_instances) do
        local device = device_instances[k]
        local parameter = device:parameter(parameter_index)

        print(("        %s: %d, min(%d), $max(%d), quantum(%d), default(%d)."):format(
            parameter.name,
            parameter.value,
            parameter.value_min,
            parameter.value_max,
            parameter.value_quantum,
            parameter.value_default
        ))
    end
end

function enumerate_tracks()
    -- print('enumerate_tracks')
    
    local song = renoise.song()

    for t = 1, table.getn(song.tracks) do
        if (dialog and not dialog.visible) then
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
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local device = track:device(d)

        if (device.is_active) then
            vb.views.status.text = track.name .. ': ' .. device.name
            
            if (not devices[device.name]) then
                print('Resetting device "' .. device.name .. '".')
                devices[device.name] = {}
            end
            
            if (not devices[device.name]["instances"]) then
                print('Resetting device instances for "' .. device.name .. '".')
                devices[device.name]["instances"] = {}
            end

            table.insert(devices[device.name]["instances"], device)
        end

        coroutine.yield()
    end
end

function enumerate_parameters(device_name)
    -- print('enumerate_parameters')

    if (devices and
        devices[device_name] and
        type(devices[device_name]) == "table" and
        devices[device_name]["parameters"] and
        type(devices[device_name]["parameters"]) == "table") then
        print('Returning cached parameters for "' .. device_name .. '".')
        return devices[device_name]["parameters"]
    end

    local device = devices[device_name]["instances"][1]
    local parameters = {}

    for p = 1, table.getn(device.parameters) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return parameters
        end

        local parameter = device:parameter(p)

        vb.views.status.text = device.name .. ': ' .. parameter.name

        table.insert(parameters, parameter.name)

        -- parameter.record_value(value)

        coroutine.yield()
    end

    -- rprint(parameters)

    devices[device.name]["parameters"] = parameters

    -- rprint(devices)

    return parameters
end

function do_oversample()

end

function done_oversampling()
end
