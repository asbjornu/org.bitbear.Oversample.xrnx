-- Settings-grid layout: fixed column widths, the dialog shell, and the
-- per-row/device view construction.
--
-- Load-safe: the ViewBuilder, the core module, the shared state, the sibling
-- modules, and the coordinator's callbacks (device/parameter selection, the
-- action buttons) are all injected, so requiring this module never touches the
-- host at load time.
return function(deps)
    local renoise = deps.renoise
    local core = deps.core
    local state = deps.state
    local cache = deps.cache
    local devices = deps.devices
    local osig = deps.osig
    local vb = deps.vb
    local create_settings_row_identifiers = deps.create_settings_row_identifiers
    local set_main_buttons_active = deps.set_main_buttons_active
    local handlers = deps.handlers

    local layout = {}

    local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
    local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
    local CONTENT_HEIGHT = renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT
    local COLUMN_WIDTH = 16 * CONTENT_HEIGHT
    local HALF_COLUMN_WIDTH = 8 * CONTENT_HEIGHT

    -- Renoise's ViewBuilder has no "fixed column layout" mode and exposes no text
    -- metrics. To keep the Parameter/Value/Secondary columns aligned across every row
    -- we give each control in a column the same fixed width. Those widths are derived
    -- from the widest *known* label (estimated from its character length) so the
    -- columns hug their content instead of being arbitrarily wide.
    local function estimate_text_width(str)
        return math.ceil(tostring(str):len() * CONTENT_HEIGHT * 0.4) + 16
    end

    local function max_text_width(strings)
        local w = 0
        for _, s in ipairs(strings) do
            local e = estimate_text_width(s)
            if e > w then
                w = e
            end
        end
        return w
    end

    -- Tighter estimate for right-aligned labels: those live in the left part of a
    -- column (text hugging its control), so an over-estimated width leaves an
    -- obvious empty gap in front of the text. Use a smaller factor here.
    local function tight_text_width(strings)
        local w = 0
        for _, s in ipairs(strings) do
            local e = math.ceil(tostring(s):len() * CONTENT_HEIGHT * 0.3) + 8
            if e > w then
                w = e
            end
        end
        return w
    end

    local _param_names = {}
    local _value_labels = {}
    local _secondary_labels = {}
    -- Secondary resolution labels across devices. Pro-Q 3's dependent "Processing Resolution"
    -- can reach "Very High" / "Maximum", which are wider than the other entries, so they must be
    -- included or the secondary popup clips those options.
    local _secondary_values = { "Off", "On", "Stereo", "Mid-Side",
       "Low", "Medium", "High", "Very High", "Maximum" }

    for _, v in pairs(core.known_devices_parameters) do
        if type(v) == "string" then
            _param_names[#_param_names + 1] = v
        elseif type(v) == "table" then
            if v.primary then _param_names[#_param_names + 1] = v.primary end
            if v[1] then _param_names[#_param_names + 1] = v[1] end
            local sn = nil
            if type(v.secondary) == "table" and v.secondary.name then
                sn = v.secondary.name
            elseif type(v.secondary) == "string" then
                sn = v.secondary
            elseif type(v[2]) == "string" then
                sn = v[2]
            elseif type(v[2]) == "table" and v[2].name then
                sn = v[2].name
            end
            if sn then
                _secondary_labels[#_secondary_labels + 1] = sn .. ":"
            end
        end
    end

    for norm, entries in pairs(core.known_osig) do
        local axes = core.known_osig_axes and core.known_osig_axes[norm]
        if axes then
            for _, l in ipairs(axes[1].labels) do
                _value_labels[#_value_labels + 1] = l
            end
        else
            for _, e in ipairs(entries) do
                if e.values then
                    for label in pairs(e.values) do
                        _value_labels[#_value_labels + 1] = label
                    end
                end
            end
        end
    end

    for _, axes in pairs(core.known_osig_axes or {}) do
        for _, axis in ipairs(axes) do
            _secondary_labels[#_secondary_labels + 1] = tostring(axis.name) .. ":"
            for _, l in ipairs(axis.labels) do
                _secondary_values[#_secondary_values + 1] = l
            end
        end
    end

    local PARAMETER_WIDTH = max_text_width(_param_names)
    local VALUE_WIDTH = max_text_width(_value_labels)
    local SECONDARY_LABEL_WIDTH = tight_text_width(_secondary_labels)
    local SECONDARY_POPUP_WIDTH = max_text_width(_secondary_values)
    local SETTINGS_WIDTH = COLUMN_WIDTH + PARAMETER_WIDTH + VALUE_WIDTH
        + SECONDARY_LABEL_WIDTH + SECONDARY_POPUP_WIDTH + 16 + 5 * DEFAULT_CONTROL_SPACING

    layout.widths = {
        COLUMN_WIDTH = COLUMN_WIDTH,
        HALF_COLUMN_WIDTH = HALF_COLUMN_WIDTH,
        PARAMETER_WIDTH = PARAMETER_WIDTH,
        VALUE_WIDTH = VALUE_WIDTH,
        SECONDARY_LABEL_WIDTH = SECONDARY_LABEL_WIDTH,
        SECONDARY_POPUP_WIDTH = SECONDARY_POPUP_WIDTH,
        SETTINGS_WIDTH = SETTINGS_WIDTH,
        CONTENT_MARGIN = CONTENT_MARGIN,
        CONTENT_HEIGHT = CONTENT_HEIGHT,
        DEFAULT_CONTROL_SPACING = DEFAULT_CONTROL_SPACING,
    }

    -- The dialog shell (header row, settings container, footer + action buttons).
    function layout.build_dialog_view()
        return vb:row {
            id = "org.bitbear.Oversample",
            margin = CONTENT_MARGIN,
            vb:column {
                vb:row {
                    spacing = DEFAULT_CONTROL_SPACING,
                    vb:text {
                        text = "Device",
                        width = COLUMN_WIDTH
                    },
                    vb:text {
                        text = "Parameter",
                        width = PARAMETER_WIDTH,
                        align = "right"
                    },
                    vb:text {
                        text = "Value",
                        width = VALUE_WIDTH
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
                    width = SETTINGS_WIDTH,
                    -- Unlike text, multiline_text does not grow when status messages change.
                    vb:multiline_text {
                        id = "status",
                        text = "Finding devices...",
                        width = SETTINGS_WIDTH - 3 * HALF_COLUMN_WIDTH - 2 * DEFAULT_CONTROL_SPACING,
                        height = CONTENT_HEIGHT,
                        style = "body"
                    },
                    vb:row {
                        -- Renoise inserts DEFAULT_CONTROL_SPACING between these three buttons;
                        -- model it so the footer width math (and the layout test) stays honest.
                        spacing = DEFAULT_CONTROL_SPACING,
                        vb:button {
                            id = "minimize_values_button",
                            text = "Minimize",
                            width = HALF_COLUMN_WIDTH,
                            active = false,
                            notifier = function()
                                handlers.extreme_values("min")
                            end
                        },
                        vb:button {
                            id = "maximize_values_button",
                            text = "Maximize",
                            width = HALF_COLUMN_WIDTH,
                            active = false,
                            notifier = function()
                                handlers.extreme_values("max")
                            end
                        },
                        vb:button {
                            id = "set_values_button",
                            text = "Set",
                            width = HALF_COLUMN_WIDTH,
                            color = { 165, 73, 35 },
                            active = false,
                            notifier = function()
                                handlers.set_values()
                            end
                        }
                    }
                }
            }
        }
    end

    function layout.create_settings_row()
        local prev_settings_row_identifiers = create_settings_row_identifiers()

        local add_button = vb.views[prev_settings_row_identifiers.add_button_id]
        local settings_row = vb.views[prev_settings_row_identifiers.settings_row_id]
        if settings_row and add_button then
            settings_row:remove_child(add_button)
        end

        state.settings_row_count = state.settings_row_count + 1
        local row_number = state.settings_row_count
        local settings_row_identifiers = create_settings_row_identifiers()

        local device_popup_id = settings_row_identifiers.device_popup_id
        local parameter_popup_id = settings_row_identifiers.parameter_popup_id
        local parameter_label_id = settings_row_identifiers.parameter_label_id
        local parameter_value_popup_id = settings_row_identifiers.parameter_value_popup_id
        local parameter_value_slider_id = settings_row_identifiers.parameter_value_slider_id
        local parameter_value_secondary_popup_id = settings_row_identifiers.parameter_value_secondary_popup_id
        local parameter_value_secondary_label_id = settings_row_identifiers.parameter_value_secondary_label_id
        local settings_row_id = settings_row_identifiers.settings_row_id
        local add_button_id = settings_row_identifiers.add_button_id

        return vb:row {
            id = settings_row_id,
            spacing = DEFAULT_CONTROL_SPACING,
            vb:popup {
                id = device_popup_id,
                width = COLUMN_WIDTH,
                active = false,
                notifier = function(value)
                    local device_name = vb.views[device_popup_id].items[value]
                    handlers.device_selected(value, device_name, parameter_popup_id, row_number)
                end,
            },
            vb:popup {
                id = parameter_popup_id,
                width = PARAMETER_WIDTH,
                active = false,
                notifier = function(value)
                    local parameter_name = vb.views[parameter_popup_id].items[value]
                    local device_popup = vb.views[device_popup_id]
                    local selected_device_index = device_popup.value
                    local device_name = device_popup.items[selected_device_index]
                    handlers.parameter_selected(value, parameter_name, device_name, row_number)
                end,
            },
            vb:text {
                id = parameter_label_id,
                width = PARAMETER_WIDTH,
                align = "right",
                visible = false
            },
            vb:popup {
                id = parameter_value_popup_id,
                width = VALUE_WIDTH,
                active = false,
                visible = false,
                notifier = function(value)
                    if not state.selected_devices[row_number] then
                        return
                    end
                    local device_popup = vb.views[device_popup_id]
                    local device_name = device_popup.items[device_popup.value]
                    local device_instances = devices.ensure_device_instances(device_name)
                    if not device_instances[1] then
                        return
                    end
                    local choices = state.selected_devices[row_number].parameter_choices
                    if state.selected_devices[row_number].osig_driven then
                        -- VST3 row: record the chosen label (the value is applied via
                        -- the state-chunk signature, not a host parameter).
                        if choices and choices[value] then
                            local lbl = choices[value].label
                            if state.selected_devices[row_number].osig_multi_axis then
                                -- Rebuild the combined key from the (changed) primary axis and
                                -- the current secondary axis selection.
                                local axes = state.selected_devices[row_number].osig_axes
                                local a2 = state.selected_devices[row_number].osig_axis2_label
                                if a2 == nil and axes and axes[2] then
                                    a2 = axes[2].labels[1]
                                end
                                state.selected_devices[row_number].osig_target_label = osig.join_target_label(lbl, a2)
                            else
                                state.selected_devices[row_number].osig_target_label = lbl
                                state.selected_devices[row_number].osig_target_label_sec = nil
                            end
                        end
                    else
                        local v
                        if choices and choices[value] then
                            v = choices[value].value
                        end
                        if v ~= nil then
                            state.selected_devices[row_number].parameter_value = v
                        end
                    end
                    handlers.update_secondary(row_number, device_name, device_instances)
                end,
            },
            vb:slider {
                id = parameter_value_slider_id,
                width = VALUE_WIDTH,
                active = false,
                notifier = function(value)
                    local parameter_value = value
                    local parameter_name = state.selected_devices[row_number].parameter_name
                    local device_popup = vb.views[device_popup_id]
                    local device_name = device_popup.items[device_popup.value]
                    handlers.parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
                end,
            },
            -- Reserve the secondary column without drawing empty, disabled controls.
            vb:row {
                width = SECONDARY_LABEL_WIDTH + SECONDARY_POPUP_WIDTH + DEFAULT_CONTROL_SPACING,
                height = CONTENT_HEIGHT,
                spacing = DEFAULT_CONTROL_SPACING,
                vb:text {
                    id = parameter_value_secondary_label_id,
                    width = SECONDARY_LABEL_WIDTH,
                    align = "right",
                    text = "",
                    visible = false
                },
                vb:popup {
                    id = parameter_value_secondary_popup_id,
                    width = SECONDARY_POPUP_WIDTH,
                    items = {""},
                    value = 1,
                    active = false,
                    visible = false,
                    notifier = function(value)
                        if not state.selected_devices[row_number] then
                            return
                        end
                        local device_popup = vb.views[device_popup_id]
                        local device_name = device_popup.items[device_popup.value]
                        local device_instances = devices.ensure_device_instances(device_name)
                        if not device_instances[1] then
                            return
                        end
                        local sec_index = state.selected_devices[row_number].secondary_parameter_index
                        if state.selected_devices[row_number].osig_driven then
                            if state.selected_devices[row_number].osig_multi_axis then
                                -- Independent axis: the secondary popup holds this device's own
                                -- axis-2 labels; rebuild the combined key from the current
                                -- primary axis value and the newly chosen axis-2 label.
                                local axes = state.selected_devices[row_number].osig_axes
                                local sec_labels = axes and axes[2] and axes[2].labels
                                if sec_labels and sec_labels[value] then
                                    local a2 = sec_labels[value]
                                    local a1 = osig.split_target_label(
                                        state.selected_devices[row_number].osig_target_label)
                                    state.selected_devices[row_number].osig_axis2_label = a2
                                    state.selected_devices[row_number].osig_target_label =
                                        osig.join_target_label(a1, a2)
                                end
                            else
                                -- VST3 row: record the chosen secondary label for the combined
                                -- osig target key.
                                local choices = state.selected_devices[row_number].secondary_parameter_choices
                                if choices and choices[value] then
                                    state.selected_devices[row_number].osig_target_label_sec = choices[value].label
                                end
                            end
                        elseif sec_index then
                            local choices = state.selected_devices[row_number].secondary_parameter_choices
                            local v
                            if choices and choices[value] then
                                v = choices[value].value
                            end
                            if v ~= nil then
                                state.selected_devices[row_number].secondary_parameter_value = v
                            end
                        end
                    end,
                },
            },
            vb:button {
                id = add_button_id,
                text = "+",
                width = 16,
                notifier = function()
                    local new_row = layout.create_settings_row()
                    vb.views.settings_container:add_child(new_row)
                    local new_row_identifiers = create_settings_row_identifiers()
                    layout.add_device_items(new_row_identifiers.device_popup_id)
                end,
            },
        }
    end

    function layout.render_settings_rows(device_names)
        local container = vb.views.settings_container
        state.settings_row_count = 0

        local sorted_names = {}
        for _, n in ipairs(device_names) do
            sorted_names[#sorted_names + 1] = n
        end
        table.sort(sorted_names)
        device_names = sorted_names

        -- Only known devices have a meaningful oversampling parameter to drive, so
        -- only they get a row automatically. Use known_primary (not the raw map) so the
        -- predicate matches device_selected: a VST3 build is only "known" when a chunk
        -- signature exists for it, otherwise an unsupported VST3 row would be auto-added.
        -- Each row's device dropdown still lists every device in the song, so any row can
        -- be reassigned by hand. The format prefix (VST/VST3/AU) is normalized away inside
        -- known_primary so one entry matches every format.
        local known_names = {}
        for _, n in ipairs(device_names) do
            if core.known_primary(n) then
                known_names[#known_names + 1] = n
            end
        end

        for _, device_name in ipairs(known_names) do
            local settings_row = layout.create_settings_row()
            container:add_child(settings_row)
            local settings_row_identifiers = create_settings_row_identifiers()
            local device_popup_id = settings_row_identifiers.device_popup_id

            local idx = 1
            for i, n in ipairs(device_names) do
                if n == device_name then
                    idx = i
                    break
                end
            end

            if vb.views[device_popup_id] then
                local devices_popup = vb.views[device_popup_id]
                devices_popup.items = device_names
                devices_popup.value = idx
                devices_popup.active = true
            end
        end

        set_main_buttons_active(true)
    end

    function layout.add_device_items_init()
        local ok, err = xpcall(function()
            state.devices_valid = true

            local device_items = core.collect_device_items(state.devices, state.cached_device_names)

            table.sort(device_items)

            state.cached_device_names = device_items
            cache.save_global_device_name_cache()

            layout.render_settings_rows(device_items)

            -- Per-row parameter scans may still be running in the background.
            if state.pending_parameter_scans == 0 then
                vb.views.status.text = 'Done.'
            end
        end, debug.traceback)
        if not ok then
            print("OVERSAMPLE add_device_items_init ERROR:\n" .. tostring(err))
        end
    end

    function layout.add_device_items(device_popup_id, selected_device_index)
        local device_items = {}
        set_main_buttons_active(false)

        -- Offer the full, current device list so any row can target any device in
        -- the song. `cached_device_names` is kept in sync with the live song by the
        -- device-change handlers, whereas the `devices` map can be stale after a
        -- device is added or removed.
        for _, n in ipairs(state.cached_device_names) do
            device_items[#device_items + 1] = n
        end

        table.sort(device_items)

        if vb.views[device_popup_id] then
            local devices_popup = vb.views[device_popup_id]
            devices_popup.items = device_items
            devices_popup.active = true
            if selected_device_index then
                devices_popup.value = selected_device_index
            end
        else
            print('Could not add items to "' .. device_popup_id .. '" as it does not exist.')
        end

        set_main_buttons_active(true)
        -- A parameter scan may still be running in the background.
        if state.pending_parameter_scans == 0 then
            vb.views.status.text = 'Done.'
        end
    end

    -- Refresh every device dropdown in the currently rendered settings rows so that
    -- newly added (or removed) devices become (un)selectable. The currently chosen
    -- device is preserved when it still exists in the song.
    function layout.refresh_device_popups()
        local names = {}
        for _, n in ipairs(state.cached_device_names) do
            names[#names + 1] = n
        end
        table.sort(names)

        for i = 1, state.settings_row_count do
            local ids = create_settings_row_identifiers(i)
            local device_popup_id = ids.device_popup_id
            local popup = vb.views[device_popup_id]
            if popup then
                local selected_name = popup.items[popup.value]
                popup.items = names
                local new_index = 1
                if selected_name then
                    for j, n in ipairs(names) do
                        if n == selected_name then
                            new_index = j
                            break
                        end
                    end
                end
                popup.value = new_index
                popup.active = (#names > 0)
            end
        end
    end

    -- Set of device names currently chosen in the rendered settings rows.
    local function rendered_device_name_set()
        local set = {}
        for i = 1, state.settings_row_count do
            local ids = create_settings_row_identifiers(i)
            local popup = vb.views[ids.device_popup_id]
            if popup and popup.items and popup.value and popup.items[popup.value] then
                set[popup.items[popup.value]] = true
            end
        end
        return set
    end

    -- Append a new settings row already pointing at the given device and populate its
    -- parameter controls, exactly as if the user had added a row and picked it.
    local function add_row_for_device(device_name)
        local settings_row = layout.create_settings_row()
        vb.views.settings_container:add_child(settings_row)
        local ids = create_settings_row_identifiers()
        local device_popup_id = ids.device_popup_id
        local parameter_popup_id = ids.parameter_popup_id

        layout.add_device_items(device_popup_id)

        local popup = vb.views[device_popup_id]
        if popup then
            for i, n in ipairs(popup.items) do
                if n == device_name then
                    popup.value = i
                    handlers.device_selected(i, device_name, parameter_popup_id, state.settings_row_count)
                    break
                end
            end
        end
    end

    -- When a known device appears in the song, add a row for it automatically so the
    -- user does not have to do it by hand. Devices already represented by a row are
    -- skipped to avoid duplicates.
    function layout.add_rows_for_new_known_devices()
        if not state.dialog or not state.dialog.visible then
            return
        end

        local rendered = rendered_device_name_set()
        for _, name in ipairs(state.cached_device_names) do
            -- Same gate as device_selected: core.known_primary returns nil for an unsupported
            -- VST3 build (no signature), so such a plugin added after the dialog is open is not
            -- auto-added as an inactive row.
            if core.known_primary(name) and not rendered[name] then
                add_row_for_device(name)
            end
        end
    end

    return layout
end
