-- Per-row parameter/secondary state machine: enum probing, the value
-- control, the dependent/independent secondary dropdowns, device/parameter
-- selection, and the Minimize/Maximize preview.
--
-- Load-safe: the core module, the shared state, the sibling modules, the shared
-- ViewBuilder, and the coordinator's callbacks are all injected, so requiring
-- this module never touches the host at load time.
return function(deps)
    local core = deps.core
    local state = deps.state
    local osig = deps.osig
    local devices = deps.devices
    local vb = deps.vb
    local create_settings_row_identifiers = deps.create_settings_row_identifiers
    local activity = deps.activity
    local mark_parameter_scan_started = deps.mark_parameter_scan_started
    local mark_parameter_scan_finished = deps.mark_parameter_scan_finished
    local process_slicer = deps.process_slicer

    local match_parameter = core.match_parameter
    local known_primary = core.known_primary
    local known_secondary = core.known_secondary
    local nearest_choice_index = core.nearest_choice_index

    local M = {}

-- Classify a parameter as an enum (dropdown) or a continuous slider. Renoise
-- exposes no enum labels and some enums report value_quantum == 0, so we probe a
-- range and count the distinct snapped values: 2..64 distinct, non-empty labels
-- is an enum, otherwise a slider. The result is cached by (name, range, quantum).
local function parameter_choices(parameter)
    local min_v = parameter.value_min
    local max_v = parameter.value_max
    local q = parameter.value_quantum

    local cache_key
    if q and q > 0 then
        cache_key = parameter.name .. "\0" .. min_v .. "\0" .. max_v .. "\0" .. q
    else
        cache_key = parameter.name .. "\0" .. min_v .. "\0" .. max_v .. "\0q0"
    end
    if state.parameter_choices_cache[cache_key] then
        return state.parameter_choices_cache[cache_key]
    end

    -- Probe a [lo, hi] range in `steps + 1` increments and collect the distinct
    -- snapped values. Deduping by the snapped *value* (not by the label string)
    -- is what makes VST3 enums work: many VST3 plugins expose enums over a
    -- normalised [0, 1] range and either report a misleading value_quantum or
    -- return a numeric / probe-dependent value_string, while the underlying
    -- value still snaps to a small set of discrete steps. Counting the distinct
    -- snapped values reveals the real number of choices.
    local function probe_range(lo, hi, steps)
        local original = parameter.value
        local choices = {}
        local seen = {}
        local span = hi - lo
        if span <= 0 then
            span = 1
        end
        for k = 0, steps do
            local v = lo + span * (k / steps)
            local ok, s, tv = pcall(function()
                parameter.value = v
                return parameter.value_string, parameter.value
            end)
            if ok and type(s) == "string" and type(tv) == "number" then
                -- A parameter with distinct snapped values but an empty (or
                -- whitespace-only) display string is not an enum; skip it so it
                -- does not render a popup full of blank entries.
                local label = s:match("^%s*(.-)%s*$")
                local key = string.format("%.12f", tv)
                if label ~= "" and not seen[key] then
                    seen[key] = true
                    choices[#choices + 1] = { value = tv, label = label }
                end
            end
        end
        pcall(function()
            parameter.value = original
        end)
        return choices
    end

    local choices
    if q and q > 0 then
        local n = math.floor((max_v - min_v) / q + 0.5)
        if n < 2 then
            n = 2
        end
        if n > 256 then
            n = 256
        end
        choices = probe_range(min_v, max_v, n)
        -- A misleading quantum (common with VST3) can collapse the probe onto a
        -- single step. When that happens, fall back to a full-range scan which
        -- still collapses correctly for a real enum but spreads out for a
        -- continuous parameter.
        if #choices < 2 then
            choices = probe_range(min_v, max_v, 128)
        end
    else
        choices = probe_range(min_v, max_v, 128)
    end

    state.parameter_choices_cache[cache_key] = choices
    return choices
end

-- An enum (dropdown) is any parameter with a small set of distinct labels.
local function is_parameter_enum(parameter)
    local choices = parameter_choices(parameter)
    return #choices >= 2 and #choices <= 64
end

-- known_primary / known_secondary are provided by the core module.

-- A dependent secondary is shown only when the primary parameter's current
-- value matches this string (Pro-Q: "Processing Resolution" appears once
-- "Processing Mode" is set to "Linear Phase").
local SECONDARY_SHOW_WHEN = 'Linear Phase'

local function loose_eq(a, b)
    local function t(s)
        return tostring(s):lower():match("^%s*(.-)%s*$")
    end
    return t(a) == t(b)
end

-- Resolve a known parameter name to its index within a list of parameter
-- names. Plugins do not always expose the exact name we expect, so we match
-- exactly first, then case-insensitively (ignoring surrounding whitespace),
-- then by substring (the known name appearing inside the real name). The last
-- fallback catches e.g. "Oversampling" vs "Oversampling Rate".
-- match_parameter is provided by the core module.

-- Show/hide and populate the dependent secondary dropdown. Only relevant when
-- the selected parameter is the device's known primary and its value equals
-- nearest_choice_index is provided by the core module.

-- SECONDARY_SHOW_WHEN.

-- Hide the reserved secondary controls and clear their per-row state. The
-- enclosing row keeps its fixed width while these are invisible.
local function clear_secondary(row_number)
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids.parameter_value_secondary_popup_id]
    local sec_label = vb.views[ids.parameter_value_secondary_label_id]
    sec_popup.items = {""}
    sec_popup.value = 1
    sec_popup.active = false
    sec_popup.visible = false
    if sec_label then
        sec_label.text = ""
        sec_label.visible = false
    end
    local sd = state.selected_devices[row_number]
    sd.secondary_parameter_index = nil
    sd.secondary_parameter_value = nil
    sd.secondary_parameter_name = nil
    sd.osig_target_label_sec = nil
end

local function update_secondary_osig(row_number, device_name)
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids.parameter_value_secondary_popup_id]
    local sec_label = vb.views[ids.parameter_value_secondary_label_id]
    local sec_name = known_secondary(device_name)
    local primary_name = known_primary(device_name)

    local function hide_secondary()
        clear_secondary(row_number)
    end

    -- Multiple independent oversampling axes (e.g. Saturn 2's "High Quality" mode and
    -- "Linear Phase" toggle): the secondary popup shows the next axis' labels directly
    -- from the signature metadata, with no sibling host parameter involved.
    if state.selected_devices[row_number] and state.selected_devices[row_number].osig_multi_axis then
        local axes = state.selected_devices[row_number].osig_axes
        if axes and axes[2] then
            local sec_labels = axes[2].labels
            local a2 = state.selected_devices[row_number].osig_axis2_label
            local sidx = 1
            for i, l in ipairs(sec_labels) do
                if l == a2 then
                    sidx = i
                    break
                end
            end
            sec_popup.items = sec_labels
            sec_popup.value = sidx
            sec_popup.active = true
            sec_popup.visible = true
            if sec_label then
                sec_label.text = axes[2].name .. ":"
                sec_label.visible = true
            end

            -- Multi-axis devices have no dependent (sibling) secondary; clear any stale
            -- state left by a previously-selected device so osig_target_for_row() never
            -- appends a leftover secondary label (e.g. "Off / On / Medium").
            state.selected_devices[row_number].secondary_parameter_choices = nil
            state.selected_devices[row_number].secondary_parameter_index = nil
            state.selected_devices[row_number].secondary_parameter_value = nil
            state.selected_devices[row_number].secondary_parameter_name = nil
            state.selected_devices[row_number].osig_target_label_sec = nil
            return
        end
    end

    if not sec_name or not primary_name then
        hide_secondary()
        return
    end
    if state.selected_devices[row_number].parameter_name ~= primary_name then
        hide_secondary()
        return
    end

    -- The VST3 device does not expose the parameter, so the secondary labels come
    -- from the sibling device's parameter.
    local sibling = state.selected_devices[row_number].sibling_device
    if not sibling then
        hide_secondary()
        return
    end

    local primary_label = state.selected_devices[row_number].osig_target_label
    -- osig labels can combine multiple axes (e.g. Pro-Q 3's "Linear Phase / Medium");
    -- only the portion before the " / " separator is the primary-axis value we compare
    -- against SECONDARY_SHOW_WHEN, so the dependent secondary still appears for those
    -- modes. The trailing portion is the dependent-secondary value the combined label
    -- already implies (e.g. the "Maximum" in "Linear Phase / Maximum"), used to seed the
    -- secondary so Minimize/Maximize land on the correct resolution rather than the
    -- first choice.
    local primary_axis, primary_suffix = osig.split_target_label(primary_label)
    if not primary_label or not loose_eq(primary_axis, SECONDARY_SHOW_WHEN) then
        hide_secondary()
        return
    end

    local sec_index = match_parameter(devices.parameter_names(sibling), sec_name)
    if not sec_index then
        hide_secondary()
        return
    end

    local sec_param = sibling:parameter(sec_index)
    local sec_choices = parameter_choices(sec_param)
    local sec_labels = {}
    for i, c in ipairs(sec_choices) do
        sec_labels[i] = c.label
    end
    if state.selected_devices[row_number].osig_target_label_sec == nil and sec_choices[1] then
        -- Prefer the resolution already implied by the combined primary label (e.g. the
        -- "Maximum" in "Linear Phase / Maximum") so Minimize/Maximize land on the right
        -- resolution instead of always defaulting to the first choice.
        local initial = sec_choices[1].label
        if primary_suffix then
            for _, c in ipairs(sec_choices) do
                if c.label == primary_suffix then initial = c.label; break end
            end
        end
        state.selected_devices[row_number].osig_target_label_sec = initial
    end
    local sec_idx = 1
    local cur = state.selected_devices[row_number].osig_target_label_sec
    for i, c in ipairs(sec_choices) do
        if c.label == cur then
            sec_idx = i
            break
        end
    end
    sec_popup.items = sec_labels
    sec_popup.value = sec_idx
    sec_popup.active = true
    sec_popup.visible = true
    if sec_label then
        sec_label.text = sec_name .. ":"
        sec_label.visible = true
    end
    state.selected_devices[row_number].secondary_parameter_index = sec_index
    state.selected_devices[row_number].secondary_parameter_name = sec_param.name
    state.selected_devices[row_number].secondary_parameter_choices = sec_choices
end

local function update_secondary(row_number, device_name, device_instances)
    if state.selected_devices[row_number] and state.selected_devices[row_number].osig_driven then
        update_secondary_osig(row_number, device_name)
        return
    end
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids.parameter_value_secondary_popup_id]
    local sec_label = vb.views[ids.parameter_value_secondary_label_id]
    local sec_name = known_secondary(device_name)
    local primary_name = known_primary(device_name)

    local function hide_secondary()
        clear_secondary(row_number)
    end

    if not sec_name or not primary_name then
        hide_secondary()
        return
    end
    if state.selected_devices[row_number].parameter_name ~= primary_name then
        hide_secondary()
        return
    end

    local device = device_instances[1]
    local primary_index = state.selected_devices[row_number].parameter_index
    if not primary_index or not device then
        hide_secondary()
        return
    end
    local primary_param = device:parameter(primary_index)
    -- Use the intended value (what the user picked in the dropdown), not the
    -- plugin's possibly-stale live value, so the secondary appears as soon as
    -- "Linear Phase" is selected rather than only after "Set" is applied.
    local intended_value = state.selected_devices[row_number].parameter_value
    if intended_value == nil then
        intended_value = primary_param.value
    end

    local pchoices = parameter_choices(primary_param)
    local primary_label
    if #pchoices > 0 then
        primary_label = pchoices[nearest_choice_index(pchoices, intended_value)].label
    end

    if not primary_label or not loose_eq(primary_label, SECONDARY_SHOW_WHEN) then
        hide_secondary()
        return
    end

    local sec_index = match_parameter(devices.parameter_names(device), sec_name)
    if not sec_index then
        hide_secondary()
        return
    end

    local sec_param = device:parameter(sec_index)
    local sec_choices = parameter_choices(sec_param)
    local sec_labels = {}
    for i, c in ipairs(sec_choices) do
        sec_labels[i] = c.label
    end
    local sec_idx = nearest_choice_index(sec_choices, sec_param.value)
    sec_popup.items = sec_labels
    sec_popup.value = sec_idx
    sec_popup.active = true
    sec_popup.visible = true
    if sec_label then
        sec_label.text = sec_name .. ":"
        sec_label.visible = true
    end
    state.selected_devices[row_number].secondary_parameter_index = sec_index
    state.selected_devices[row_number].secondary_parameter_name = sec_param.name
    state.selected_devices[row_number].secondary_parameter_value = sec_param.value
    state.selected_devices[row_number].secondary_parameter_choices = sec_choices
end

-- Populate the value control (dropdown for enums, slider otherwise) for the
-- chosen parameter using an explicit target value, and refresh any dependent
-- secondary control. Used both when reflecting a live device value and when
-- previewing an extreme (min/max) value in the UI without touching the device.
local function apply_value_to_control(row_number, device_name, device_instances, parameter_index, target_value)
    local device = device_instances[1]
    local parameter = device:parameter(parameter_index)
    local ids = create_settings_row_identifiers(row_number)
    local popup = vb.views[ids.parameter_value_popup_id]
    local slider = vb.views[ids.parameter_value_slider_id]

    state.selected_devices[row_number].parameter_index = parameter_index
    state.selected_devices[row_number].parameter_name = parameter.name
    state.selected_devices[row_number].parameter_value = target_value

    if is_parameter_enum(parameter) then
        local choices = parameter_choices(parameter)
        local labels = {}
        for i, c in ipairs(choices) do
            labels[i] = c.label
        end
        local idx = nearest_choice_index(choices, target_value)
        popup.items = labels
        popup.value = idx
        popup.active = true
        slider.visible = false
        popup.visible = true
        state.selected_devices[row_number].parameter_choices = choices
    else
        slider.min = parameter.value_min
        slider.max = parameter.value_max
        slider.value = target_value
        slider.active = true
        popup.visible = false
        slider.visible = true
        state.selected_devices[row_number].parameter_choices = nil
    end

    update_secondary(row_number, device_name, device_instances)
end

-- Reflect a device's current parameter value in the UI (the default behaviour
-- used after scans and after "Set" is applied).
local function set_value_control(row_number, device_name, device_instances, parameter_index)
    local device = device_instances[1]
    if not device then
        return
    end
    local parameter = device:parameter(parameter_index)
    apply_value_to_control(row_number, device_name, device_instances, parameter_index, parameter.value)
end

-- Build the value dropdown for a row whose known parameter is NOT exposed by the
-- device itself (VST3). The labels come from a sibling device's parameter choices;
-- the value is applied through the VST3 state-chunk signature. The current label
-- is detected from the live VST3 blob when a signature exists, otherwise the first
-- choice is assumed.
local function show_osig_dropdown(row_number, device_name, device_instances,
    choices, parameter_name, sibling, sibling_index)
    state.selected_devices[row_number].parameter_name = parameter_name
    state.selected_devices[row_number].parameter_index = nil
    state.selected_devices[row_number].osig_driven = true
    state.selected_devices[row_number].sibling_device = sibling
    state.selected_devices[row_number].sibling_primary_index = sibling_index
    state.selected_devices[row_number].parameter_choices = choices

    local ids = create_settings_row_identifiers(row_number)
    local popup = vb.views[ids.parameter_value_popup_id]
    local slider = vb.views[ids.parameter_value_slider_id]

    local labels = {}
    for i, c in ipairs(choices) do
        labels[i] = c.label
    end

    local target_label = choices[1] and choices[1].label
    local entries = state.osig[core.normalize_device_name(device_name)]
    if entries and #entries > 0 then
        local dev = device_instances[1]
        local ok, blob = pcall(function()
            return dev.active_preset_data
        end)
        if ok and type(blob) == "string" and blob ~= "" then
            local cur
            if blob:match("<ParameterChunk>") then
                cur = core.detect_label_xml(blob, entries)
            else
                cur = core.detect_label(blob, entries)
            end
            if cur then
                target_label = cur
            end
        end
    end
    state.selected_devices[row_number].osig_target_label = target_label

    local idx = 1
    if state.selected_devices[row_number].osig_multi_axis then
        -- target_label is the combined "axis1 / axis2"; the primary popup only shows
        -- axis1, and the secondary popup (filled by update_secondary) shows axis2.
        local axes = state.selected_devices[row_number].osig_axes
        local a1, a2 = osig.split_target_label(target_label)
        if type(target_label) == "string" and a2 == nil then
            -- No separator: default the second axis to its first (off) label so the
            -- stored target is always the full combined key.
            a2 = axes[2] and axes[2].labels[1]
            target_label = a1 .. osig.SECONDARY_SEP .. (a2 or "")
            state.selected_devices[row_number].osig_target_label = target_label
        end
        state.selected_devices[row_number].osig_axis2_label = a2
        for i, c in ipairs(choices) do
            if c.label == a1 then
                idx = i
                break
            end
        end
    else
        for i, c in ipairs(choices) do
            if c.label == target_label then
                idx = i
                break
            end
        end
    end
    popup.items = labels
    popup.value = idx
    popup.active = true
    slider.visible = false
    popup.visible = true

    update_secondary(row_number, device_name, device_instances)
end

-- Update the value slider for a chosen parameter without scanning the whole
-- plugin: find the parameter by name in a single tight pass (no coroutine
-- yields) and read its current value directly. This lets the "Oversample"
-- parameter's slider react instantly, before the full list is enumerated.
local function apply_parameter_value(row_number, device_name, parameter_name)
    local device_instances = devices.ensure_device_instances(device_name)
    local device = device_instances[1]
    if not device then
        return
    end

    -- VST3 builds expose no host parameter for oversampling; go straight to the
    -- state-chunk signature without enumerating (and matching) the 344 params.
    local norm = core.normalize_device_name(device_name)
    local sig = state.osig[norm]
    if sig and #sig > 0 and device_name:sub(1, 5) == "VST3:" then
        -- Several independent oversampling fields (e.g. Saturn 2's "High Quality" mode
        -- and "Linear Phase" toggle): present one dropdown per axis. The primary popup
        -- shows the first axis' labels; a separate secondary popup shows the next axis;
        -- the combined signature label (axis1 .. " / " .. axis2) is rebuilt at patch time.
        local axes = core.osig_axes(norm)
        if axes and #axes >= 2 then
            local mchoices = {}
            for i, l in ipairs(axes[1].labels) do
                mchoices[i] = { label = l, value = i }
            end
            state.selected_devices[row_number].osig_multi_axis = true
            state.selected_devices[row_number].osig_axes = axes
            show_osig_dropdown(row_number, device_name, device_instances, mchoices, parameter_name, nil, nil)
            return
        end
        -- Not a multi-axis device: clear any stale multi-axis state left by a previously
        -- selected device so single-axis labels are not treated as combined "axis1 / axis2"
        -- keys (which would then fail to match any signature label).
        state.selected_devices[row_number].osig_multi_axis = nil
        state.selected_devices[row_number].osig_axes = nil
        local choices = osig.osig_choices_for(norm, sig)
        -- A dependent secondary (e.g. Pro-Q 3's "Processing Resolution") is driven by a
        -- sibling device that exposes the host parameter; pass it through so the secondary
        -- dropdown can appear (update_secondary_osig needs the sibling to read its values).
        local sibling, sibling_index
        local primary_name = known_primary(device_name)
        if primary_name then
            sibling, sibling_index = devices.resolve_sibling_parameter(device_name, primary_name)
        end
        show_osig_dropdown(row_number, device_name, device_instances, choices, parameter_name, sibling, sibling_index)
        return
    end

    local parameter_index = match_parameter(devices.parameter_names(device), parameter_name)
    if parameter_index then
        state.selected_devices[row_number].parameter_name = device:parameter(parameter_index).name
        state.selected_devices[row_number].parameter_index = parameter_index
        state.selected_devices[row_number].osig_driven = nil
        set_value_control(row_number, device_name, device_instances, parameter_index)
        return
    end

    -- The parameter is not exposed on this device (typical for VST3 builds, which
    -- keep oversampling out of the host-parameter list). Use a built-in
    -- state-chunk signature's labels directly (hardcoded, no sibling needed).
    norm = core.normalize_device_name(device_name)
    local entries = state.osig[norm]
    -- The osig state-chunk signatures are learned from VST3 builds, which hide
    -- oversampling from the host-parameter list. Only drive them for VST3 devices;
    -- applying a VST3-learned signature to an AU/VST2 build would patch the wrong
    -- bytes (no-op or corruption). Non-VST3 devices expose oversampling as a host
    -- parameter and are handled by the sibling/parameter paths below.
    if device_name:sub(1, 5) == "VST3:" and entries and #entries > 0 then
        show_osig_dropdown(row_number, device_name, device_instances,
            osig.osig_choices_for(norm, entries), parameter_name, nil, nil)
        return
    end
    -- Fallback: borrow labels from a sibling device of the same plugin if present.
    -- The value is applied through the VST3 state-chunk signature, so a signature
    -- must exist for this device and it must be a VST3 build. Without a signature
    -- (or for an AU/VST2 build, which apply_osig_to_device_name refuses to touch)
    -- Set cannot apply the selected target, so don't present osig controls.
    local sibling, sindex = devices.resolve_sibling_parameter(device_name, parameter_name)
    if sibling and sindex and device_name:sub(1, 5) == "VST3:"
        and entries and #entries > 0 then
        show_osig_dropdown(row_number, device_name, device_instances,
            parameter_choices(sibling:parameter(sindex)), parameter_name, sibling, sindex)
    end
    -- Neither a signature nor a sibling provides labels: nothing to drive.
end

local function device_selected(device_index, device_name, parameter_popup_id, row_number)
    activity.set(false)
    state.selected_devices[row_number] = {
         device_name = device_name,
         device_index = device_index
    }
    -- print('device_selected')

    local known_primary_name = known_primary(device_name)
    local parameters_popup = vb.views[parameter_popup_id]
    local parameter_label = vb.views[create_settings_row_identifiers(row_number).parameter_label_id]

    -- Known, hard-coded parameter: the parameter is fixed, so replace the dropdown
    -- with a static, right-aligned label (ending in a colon). This also covers VST3
    -- devices whose oversampling is driven purely through the state-chunk signature
    -- (no host parameter is exposed), so no parameter scan is needed.
    if known_primary_name then
        parameters_popup.visible = false
        parameter_label.text = known_primary_name .. ":"
        parameter_label.visible = true
        apply_parameter_value(row_number, device_name, known_primary_name)
        -- No scan is started on this path, so it must not touch the shared
        -- pending-scan counter: doing so would steal a decrement from another
        -- row's in-flight scan and report "Done." too early.
        activity.set(true)
        return
    end

    -- Unknown device: show the dropdown (and hide the label) and scan its parameters.
    parameter_label.visible = false
    parameters_popup.visible = true

    -- Populate the parameter dropdown from the (already known) full list, then
    -- snap to the recognised "Oversample" parameter. No waiting required.
    -- `started` distinguishes the asynchronous scan callback (which incremented
    -- the shared pending-scan counter) from a synchronous cache hit, so only a
    -- started scan decrements it. device_selected disabled the controls, so
    -- every exit path re-enables them.
    local function apply_parameters(parameters, started)
        if not parameters then
            parameters = {}
        end

        local function finish()
            if started then
                mark_parameter_scan_finished()
            end
            activity.set(true)
        end

        -- Only touch the UI while the Oversample dialog (and this row's popup)
        -- still exist. The scan may finish after the dialog was closed, in which
        -- case we keep the cached result but skip the visual update.
        if not state.dialog or not state.dialog.visible or not parameters_popup then
            finish()
            return
        end

        -- If the enumeration produced no usable names (e.g. the plugin's editor
        -- was closed and it exposed nothing), keep whatever is already shown
        -- (the pre-filled known parameter) instead of replacing it with
        -- placeholders.
        local has_real = false
        for _, n in ipairs(parameters) do
            if type(n) == "string" and not n:match("^%(parameter %d+%)$") then
                has_real = true
                break
            end
        end
        if not has_real then
            finish()
            return
        end

        parameters_popup.items = parameters
        parameters_popup.active = true

        if known_primary_name then
            local i = match_parameter(parameters, known_primary_name)
            if i then
                parameters_popup.value = i
            elseif state.osig[core.normalize_device_name(device_name)] then
                -- VST3 host builds don't expose the oversampling parameter, so it is
                -- not in the enumerated list. Re-establish the state-chunk dropdown
                -- (the value popup) so the oversampling choices stay visible after
                -- the full scan has overwritten the parameter popup.
                apply_parameter_value(row_number, device_name, known_primary_name)
            end
        end

        finish()
    end

    if state.cached_parameters[device_name] then
        -- Already cached (this session, song, or a previous run): no scan.
        apply_parameters(state.cached_parameters[device_name], false)
        if known_primary_name then
            apply_parameter_value(row_number, device_name, known_primary_name)
        end
        return
    end

    -- Not cached yet: show the recognised parameter(s) immediately so the user
    -- can act at once, then run the one-time scan to back-fill the rest.
    if known_primary_name then
        local items = { known_primary_name }
        parameters_popup.items = items
        parameters_popup.value = 1
        parameters_popup.active = true
        -- Reflect the known parameter's current value on the slider right away,
        -- without waiting for the full parameter scan to complete.
        apply_parameter_value(row_number, device_name, known_primary_name)
        activity.set(true)
    else
        vb.views.status.text = 'Finding parameters...'
    end

    mark_parameter_scan_started()
    local slicer = process_slicer(devices.enumerate_parameters, function(return_value)
        apply_parameters(return_value[1], true)
    end, device_name)

    -- print('enumerate_devices:ProcessSlicer:start')
    slicer:start()
end

-- Set the value slider's range/current value from a resolved parameter index.
local function parameter_selected(parameter_index, parameter_name, device_name, row_number)
    local device_instances = devices.ensure_device_instances(device_name)
    state.selected_devices[row_number].parameter_name = parameter_name
    state.selected_devices[row_number].parameter_index = parameter_index

    activity.set(false)
    set_value_control(row_number, device_name, device_instances, parameter_index)
    activity.set(true)
end

local function parameter_value_changed(parameter_value, _parameter_name, _device_name, row_number)
    state.selected_devices[row_number].parameter_value = parameter_value
end


-- Preview the minimum ("min") or maximum ("max") value of every relevant
-- parameter in the grid by moving the UI controls only. Nothing is written to the
-- plugin here; the separate "Set" button applies the resulting UI state to the
-- devices. This lets the user see the extreme before committing it.
local function extreme_values(extreme)
    activity.set(false)

    local verb = (extreme == "min") and "minimum" or "maximum"
    if vb.views.status then
        vb.views.status.text = 'Setting controls to ' .. verb .. '...'
    end

    -- Collect the rows that have a device so we can report progress and avoid
    -- re-scanning inside the sliced loop.
    local work = {}
    for row_number, selected_device in ipairs(state.selected_devices) do
        local device_name = selected_device.device_name
        if device_name then
            local device_instances = devices.ensure_device_instances(device_name)
            if #device_instances > 0 then
                -- For VST3 plugins whose oversampling is not a host parameter, set
                -- the intended dropdown label (first = minimum, last = maximum) so
                -- set_values() can drive the state chunk to that exact value.
                if selected_device.osig_driven and state.osig[core.normalize_device_name(device_name)] then
                    if selected_device.osig_multi_axis then
                        -- Minimum/Maximum spans both independent axes: both off for the
                        -- minimum, both at their highest for the maximum.
                        local axes = selected_device.osig_axes
                        local a1 = axes[1].labels
                        local a2 = axes[2].labels
                        local c1 = (extreme == "min") and a1[1] or a1[#a1]
                        local c2 = (extreme == "min") and a2[1] or a2[#a2]
                        selected_device.osig_target_label = c1 .. osig.SECONDARY_SEP .. c2
                        selected_device.osig_axis2_label = c2
                    else
                        local choices = selected_device.parameter_choices
                        if choices and #choices > 0 then
                            selected_device.osig_target_label =
                                (extreme == "min") and choices[1].label or choices[#choices].label
                            local sec_ids = create_settings_row_identifiers(row_number)
                            local sec_popup = vb.views[sec_ids.parameter_value_secondary_popup_id]
                            if sec_popup and sec_popup.visible then
                                local sch = selected_device.secondary_parameter_choices
                                if sch and #sch > 0 then
                                    selected_device.osig_target_label_sec =
                                        (extreme == "min") and sch[1].label or sch[#sch].label
                                end
                            else
                                selected_device.osig_target_label_sec = nil
                            end
                        end
                    end
                end
                work[#work + 1] = { row_number, device_name, device_instances }
            end
        end
    end

    local processed = 0
    local total = #work

    -- Set a dependent secondary popup to an explicit target value. Mirrors the
    -- secondary half of update_secondary but uses a value we choose rather than
    -- reading the device.
    local function apply_secondary_value_to_control(row_number, device_instances, sec_index, target_value)
        local device = device_instances[1]
        local sec_param = device:parameter(sec_index)
        local ids = create_settings_row_identifiers(row_number)
        local spopup = vb.views[ids.parameter_value_secondary_popup_id]
        local sec_choices = state.selected_devices[row_number].secondary_parameter_choices
        if not sec_choices then
            sec_choices = parameter_choices(sec_param)
        end
        local sec_labels = {}
        for i, c in ipairs(sec_choices) do
            sec_labels[i] = c.label
        end
        local sec_idx = nearest_choice_index(sec_choices, target_value)
        spopup.items = sec_labels
        spopup.value = sec_idx
        spopup.active = true
        spopup.visible = true
        state.selected_devices[row_number].secondary_parameter_index = sec_index
        state.selected_devices[row_number].secondary_parameter_name = sec_param.name
        state.selected_devices[row_number].secondary_parameter_value = target_value
        state.selected_devices[row_number].secondary_parameter_choices = sec_choices
    end

    -- Move the primary value control (and any revealed dependent secondary) for
    -- one row to the requested extreme, purely in the UI.
    local function display_extreme(row_number, device_name, device_instances)
        local parameter_index = state.selected_devices[row_number].parameter_index
        if not parameter_index then
            if state.selected_devices[row_number].osig_driven then
                local ids = create_settings_row_identifiers(row_number)
                local popup = vb.views[ids.parameter_value_popup_id]
                local choices = state.selected_devices[row_number].parameter_choices
                local target_label = state.selected_devices[row_number].osig_target_label
                local idx = 1
                if state.selected_devices[row_number].osig_multi_axis then
                    -- target_label is the combined "axis1 / axis2"; show axis1 in the
                    -- primary popup and let update_secondary place axis2 in the secondary.
                    local a1, a2 = osig.split_target_label(target_label)
                    state.selected_devices[row_number].osig_axis2_label = a2
                    if choices then
                        for i, c in ipairs(choices) do
                            if c.label == a1 then
                                idx = i
                                break
                            end
                        end
                    end
                elseif choices and target_label then
                    for i, c in ipairs(choices) do
                        if c.label == target_label then
                            idx = i
                            break
                        end
                    end
                end
                if popup then
                    popup.value = idx
                end
                update_secondary(row_number, device_name, device_instances)
            end
            return
        end
        local device = device_instances[1]
        local parameter = device:parameter(parameter_index)
        local target = (extreme == "min") and parameter.value_min or parameter.value_max
        apply_value_to_control(row_number, device_name, device_instances, parameter_index, target)

        -- The new primary value may reveal a dependent secondary (e.g. Pro-Q's
        -- "Processing Resolution"); if so, preview it at the same extreme.
        local sec_index = state.selected_devices[row_number].secondary_parameter_index
        if sec_index then
            local sec_param = device:parameter(sec_index)
            local sec_target = (extreme == "min") and sec_param.value_min or sec_param.value_max
            apply_secondary_value_to_control(row_number, device_instances, sec_index, sec_target)
        end
    end

    -- Run the UI update in a sliced coroutine so the dialog stays responsive.
    local function process()
        if state.dialog and not state.dialog.visible then
            return
        end
        for _, w in ipairs(work) do
            local ok, err = pcall(display_extreme, w[1], w[2], w[3])
            if not ok then
                print("OVERSAMPLE extreme_values UI error row " .. tostring(w[1]) .. ": " .. tostring(err))
            end
            processed = processed + 1
            if vb.views.status then
                if total > 0 then
                    vb.views.status.text = string.format(
                        'Setting controls to %s... (%d/%d)', verb, processed, total)
                else
                    vb.views.status.text = 'Setting controls to ' .. verb .. '...'
                end
            end
            coroutine.yield()
        end
    end

    local function done()
        if vb.views.status then
            vb.views.status.text = 'Controls set to ' .. verb .. '.'
        end
        activity.set(true)
    end

    local slicer = process_slicer(process, done)
    slicer:start()
end
    M.parameter_choices = parameter_choices
    M.is_parameter_enum = is_parameter_enum
    M.loose_eq = loose_eq
    M.clear_secondary = clear_secondary
    M.update_secondary_osig = update_secondary_osig
    M.update_secondary = update_secondary
    M.apply_value_to_control = apply_value_to_control
    M.set_value_control = set_value_control
    M.show_osig_dropdown = show_osig_dropdown
    M.apply_parameter_value = apply_parameter_value
    M.device_selected = device_selected
    M.parameter_selected = parameter_selected
    M.parameter_value_changed = parameter_value_changed
    M.extreme_values = extreme_values

    return M
end
