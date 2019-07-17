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
local selected_devices = {}
local oversampling = true
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
                    id = "oversample_button",
                    text = "Oversample",
                    width = 100,
                    active = false,
                    notifier = do_oversample
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
    local row_number = settings_row_count
    local settings_row_identifiers = create_settings_row_identifiers()

    local devices_popup_id = settings_row_identifiers["devices_popup_id"]
    local parameters_popup_id = settings_row_identifiers["parameters_popup_id"]
    local settings_row_id = settings_row_identifiers["settings_row_id"]
    local add_button_id = settings_row_identifiers["add_button_id"]

    device_popups[row_number] = devices_popup_id

    return vb:row {
        id = settings_row_id,
        vb:popup {
            id = devices_popup_id,
            width = COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                local device_name = vb.views[devices_popup_id].items[value]
                device_selected(value, device_name, parameters_popup_id, row_number)
            end,
        },
        vb:popup {
            id = parameters_popup_id,
            width = COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                local parameter_name = vb.views[parameters_popup_id].items[value]
                local selected_device_index = vb.views[devices_popup_id].value
                local device_name = vb.views[devices_popup_id].items[selected_device_index]
                parameter_selected(value, parameter_name, device_name, row_number)
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
        local devices_popup = vb.views[v]
        devices_popup.items = device_items
        devices_popup.active = true
    end

    vb.views["oversample_button"].active = true
    vb.views.status.text = 'Done.'
end

function add_device_items(devices_popup_id, selected_device_index)
    local device_items = {}
    vb.views["oversample_button"].active = false

    local i = 1
    for k, v in pairs(devices) do
        device_items[i] = k
        i = i + 1
    end

    if (vb.views[devices_popup_id]) then
        local devices_popup = vb.views[devices_popup_id]
        devices_popup.items = device_items
        devices_popup.value = selected_device_index
        devices_popup.active = true
    else
        print('Could not add items to "' .. devices_popup_id .. '" as it does not exist.')
    end

    vb.views["oversample_button"].active = true
    vb.views.status.text = 'Done.'
end

function device_selected(device_index, device_name, parameters_popup_id, row_number)
    vb.views["oversample_button"].active = false
    selected_devices[row_number] = {
         ["device_name"] = device_name,
         ["device_index"] = device_index
    }
    -- print('device_selected')

    local slicer = ProcessSlicer(enumerate_parameters, function(return_value)
        -- print('device_selected:parameters_enumerated')
        -- Unpack the return value table; the first value is the parameters returned by enumerate_parameters
        local parameters = return_value[1]

        -- rprint(parameters)
    
        vb.views.status.text = 'Done.'
        local parameters_popup = vb.views[parameters_popup_id]
        parameters_popup.items = parameters
        parameters_popup.active = true

        for known_device_name, known_parameters in pairs(known_devices_parameters) do
            vb.views["oversample_button"].active = false

            if (known_device_name == device_name) then
                for parameter_index, parameter in ipairs(parameters) do
                    vb.views["oversample_button"].active = false

                    if (type(known_parameters) == "string") then
                        if (parameter == known_parameters) then
                            parameters_popup.value = parameter_index
                        end
                    elseif (type(known_parameters) == "table") then
                        for _, v in ipairs(known_parameters) do
                            if (parameter == v) then
                                parameters_popup.value = parameter_index
                            end
                        end
                    else
                        print('Invalid parameter type for known device "' .. known_device_name .. '": ' .. type(known_parameters) .. '.')
                    end
                end
            end
        end
        
        vb.views["oversample_button"].active = true
    end, device_name)

    -- print('enumerate_devices:ProcessSlicer:start')        
    slicer:start()   
end

function parameter_selected(parameter_index, parameter_name, device_name, row_number)
    -- print(device_name)
    local device_instances = devices[device_name]["instances"]
    selected_devices[row_number]["parameter_name"] = parameter_name
    selected_devices[row_number]["parameter_index"] = parameter_index

    for k, v in ipairs(device_instances) do
        vb.views["oversample_button"].active = false
        local device = device_instances[k]
        local parameter = device:parameter(parameter_index)
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
    end

    vb.views["oversample_button"].active = true
end

function enumerate_tracks()
    -- print('enumerate_tracks')
    local song = renoise.song()

    for t = 1, table.getn(song.tracks) do
        vb.views["oversample_button"].active = false

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

    vb.views["oversample_button"].active = true
end

function enumerate_devices(track)
    vb.views["oversample_button"].active = false

    for d = 1, table.getn(track.devices) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return
        end

        local device = track:device(d)

        if (device.is_active) then
            vb.views.status.text = track.name .. ': ' .. device.name
            
            if (not devices[device.name]) then
                -- print('Resetting device "' .. device.name .. '".')
                devices[device.name] = {}
            end
            
            if (not devices[device.name]["instances"]) then
                -- print('Resetting device instances for "' .. device.name .. '".')
                devices[device.name]["instances"] = {}
            end

            table.insert(devices[device.name]["instances"], device)
        end

        coroutine.yield()
    end
end

function enumerate_parameters(device_name)
    -- print('enumerate_parameters')
    vb.views["oversample_button"].active = false

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
        vb.views["oversample_button"].active = false

        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return parameters
        end

        local parameter = device:parameter(p)

        vb.views.status.text = device.name .. ': ' .. parameter.name

        parameters[p] = parameter.name

        coroutine.yield()
    end

    -- rprint(parameters)

    devices[device.name]["parameters"] = parameters

    -- rprint(devices)

    vb.views["oversample_button"].active = true

    return parameters
end

function do_oversample()
    local oversample_button = vb.views["oversample_button"]
    oversample_button.active = false    
    local parameters_changed = 0

    for row_number, selected_device in ipairs(selected_devices) do
        local device_name = selected_device["device_name"]
        local parameter_index = selected_device["parameter_index"]

        for i, device in ipairs(devices[device_name]["instances"]) do
            local parameter = device:parameter(parameter_index)

            if (oversampling) then
                parameter:record_value(parameter.value_max)
            else
                parameter:record_value(parameter.value_min)
            end

            parameters_changed = parameters_changed + 1
        end
    end

    local verb = nil
    local button_text = nil

    if (oversampling) then
        oversampling = false
        verb = 'oversampled'
        button_text = 'Undersample'
    else
        oversampling = true
        verb = 'undersampled'
        button_text = 'Oversample'
    end

    vb.views.status.text = parameters_changed .. ' parameters ' .. verb .. '.'
    oversample_button.text = button_text
    oversample_button.active = true
end