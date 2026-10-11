-- Song scanning: device discovery, live instance resolution, parameter
-- enumeration, and the device/preset notifiers that invalidate the cache.
--
-- Load-safe: Renoise, the core module, the shared state, ProcessSlicer, and the
-- UI callbacks are injected, so requiring this module never touches the host at
-- load time.
return function(deps)
    local renoise = deps.renoise
    local core = deps.core
    local state = deps.state
    local list_count = deps.list_count
    local process_slicer = deps.process_slicer
    local vb = deps.ui.vb
    local set_main_buttons_active = deps.ui.set_main_buttons_active
    local on_song_devices_changed = deps.ui.on_song_devices_changed

    local match_parameter = core.match_parameter

    local devices = {}

    -- The ordered list of device names currently in the song (tight loop, no
    -- per-device yields). Used to refresh the persisted name list and to reconcile
    -- the cache against the live song on open.
    function devices.collect_device_names()
        local names = {}
        local seen = {}
        local song = renoise.song()
        for t = 1, list_count(song.tracks) do
            local track = song:track(t)
            for d = 1, list_count(track.devices) do
                local device = track:device(d)
                if device.is_active and not seen[device.name] then
                    seen[device.name] = true
                    names[#names + 1] = device.name
                end
            end
        end
        return names
    end

    -- A plugin's parameter list can change when its preset/program changes (some
    -- plugins expose a different set of parameters per preset). When that happens
    -- we drop the cached list so it is recomputed the next time it is needed.
    function devices.on_device_preset_changed(device)
        local name = device.name
        if state.cached_parameters[name] then
            print('Oversample: preset changed for "' .. name .. '", invalidating cache.')
            state.cached_parameters[name] = nil
            state.cache_dirty = true
            state.global_cache_dirty = true
        end
    end

    -- (Re)install the preset-change notifier on a live device. The closure is kept
    -- so the exact reference can be removed again: remove_notifier matches by
    -- function identity, so a freshly created closure would never remove the
    -- previously installed one and duplicates would accumulate.
    local function attach_preset_notifier(device)
        local observable = device.active_preset_observable
        local previous = state.device_preset_notifiers[device]
        if previous then
            pcall(function() observable:remove_notifier(previous) end)
        end
        local notifier = function()
            devices.on_device_preset_changed(device)
        end
        state.device_preset_notifiers[device] = notifier
        observable:add_notifier(notifier)
    end

    -- Lazily resolve the live device instances for a device name. The full device
    -- scan collects these once; afterwards we reuse the cached map, and if a name
    -- is needed before that scan has run we walk the song directly (and wire up the
    -- preset-change notifier so the parameter cache still invalidates).
    function devices.ensure_device_instances(device_name)
        local entry = state.devices[device_name]
        if entry and entry.instances and #entry.instances > 0 then
            return entry.instances
        end

        local instances = {}
        local song = renoise.song()
        for t = 1, list_count(song.tracks) do
            local track = song:track(t)
            for d = 1, list_count(track.devices) do
                local device = track:device(d)
                if device.is_active and device.name == device_name then
                    instances[#instances + 1] = device
                    pcall(function()
                        attach_preset_notifier(device)
                    end)
                end
            end
        end

        if not state.devices[device_name] then state.devices[device_name] = {} end
        state.devices[device_name].instances = instances
        return instances
    end

    -- The exposed parameter names of a device, in 1-based parameter-index order.
    -- A placeholder keeps the list dense when Renoise reports a nil or empty
    -- name, so a later valid parameter is not hidden by a hole in '#names'.
    function devices.parameter_names(device)
        local names = {}
        for p = 1, devices.count_parameters(device) do
            local name = device:parameter(p).name
            if name and name ~= "" then
                names[p] = name
            else
                names[p] = ("(parameter %d)"):format(p)
            end
        end
        return names
    end

    -- Find another device in the song that is the same plugin (matched by normalised
    -- name) but a different build, and which exposes the given parameter. This is how
    -- we obtain dropdown labels for a VST3 device whose oversampling parameter is not
    -- host-exposed: we borrow them from the VST2 build of the same plugin. The VST2
    -- build is preferred but any exposing sibling is accepted. Returns the device, or
    -- nil when none qualifies.
    function devices.find_sibling_device(device_name, parameter_name)
        local norm = core.normalize_device_name(device_name)
        local song = renoise.song()
        local fallback = nil
        for t = 1, list_count(song.tracks) do
            local track = song:track(t)
            for d = 1, list_count(track.devices) do
                local dev = track:device(d)
                if dev.is_active and core.normalize_device_name(dev.name) == norm
                        and dev.name ~= device_name then
                    if match_parameter(devices.parameter_names(dev), parameter_name) then
                        if dev.name:sub(1, 4) == "VST:" then
                            return dev
                        end
                        fallback = fallback or dev
                    end
                end
            end
        end
        return fallback
    end

    -- Locate a sibling build of the same plugin that exposes `parameter_name` and the
    -- 1-based index of that parameter. Returns sibling, index (both nil when absent).
    function devices.resolve_sibling_parameter(device_name, parameter_name)
        local sibling = devices.find_sibling_device(device_name, parameter_name)
        if not sibling then
            return nil, nil
        end
        return sibling, match_parameter(devices.parameter_names(sibling), parameter_name)
    end

    -- Watch every track's device list (and the track list itself) so that adding
    -- or removing a plugin invalidates the cache for the affected device types.
    function devices.attach_song_device_notifiers()
        local song = renoise.song()

        local function attach_track(track)
            pcall(function()
                track.devices_observable:remove_notifier(on_song_devices_changed)
            end)
            track.devices_observable:add_notifier(on_song_devices_changed)
        end

        for t = 1, list_count(song.tracks) do
            attach_track(song:track(t))
        end

        -- Replace any track-list notifier installed by a previous call. Keep the
        -- closure and the observable it was added to so the exact reference can be
        -- removed (a fresh anonymous closure would never match, accumulating
        -- duplicates on every new song/reopen).
        if state.song_tracks_notifier and state.song_tracks_observable then
            pcall(function()
                state.song_tracks_observable:remove_notifier(state.song_tracks_notifier)
            end)
        end
        local tracks_observable = song.tracks_observable
        local tracks_notifier = function()
            for t = 1, list_count(song.tracks) do
                attach_track(song:track(t))
            end
            on_song_devices_changed()
        end
        state.song_tracks_observable = tracks_observable
        state.song_tracks_notifier = tracks_notifier
        tracks_observable:add_notifier(tracks_notifier)
    end

    function devices.enumerate_tracks()
        local ok, err = xpcall(function()
            local song = renoise.song()

            -- Count the total number of active devices up front so the scan can show
            -- "Scanning devices... (k/total)" progress instead of flickering names.
            state.device_scan_total = 0
            state.device_scan_count = 0
            for t = 1, list_count(song.tracks) do
                local track = song:track(t)
                for d = 1, list_count(track.devices) do
                    if track:device(d).is_active then
                        state.device_scan_total = state.device_scan_total + 1
                    end
                end
            end

            for t = 1, list_count(song.tracks) do
                set_main_buttons_active(false)

                if state.dialog and not state.dialog.visible then
                    print('Dialog closed, stopping.')
                    return
                end

                local track = song:track(t)

                local slicer = process_slicer(devices.enumerate_devices, nil, track)
                slicer:start()

                coroutine.yield()
            end

            set_main_buttons_active(true)
        end, debug.traceback)
        if not ok then
            print("OVERSAMPLE enumerate_tracks ERROR:\n" .. tostring(err))
        end
    end

    function devices.enumerate_devices(track)
        local ok, err = xpcall(function()
            set_main_buttons_active(false)

            for d = 1, list_count(track.devices) do
                if state.dialog and not state.dialog.visible then
                    print('Dialog closed, stopping.')
                    return
                end

                local device = track:device(d)

                if device.is_active then
                    state.device_scan_count = state.device_scan_count + 1
                    vb.views.status.text = string.format(
                        'Scanning devices... (%d/%d)', state.device_scan_count, state.device_scan_total)

                    if not state.devices[device.name] then
                        state.devices[device.name] = {}
                    end

                    if not state.devices[device.name].instances then
                        state.devices[device.name].instances = {}
                    end

                    table.insert(state.devices[device.name].instances, device)

                    -- Invalidate the cache if this plugin's preset (and thus possibly
                    -- its parameter list) changes while the song is open.
                    pcall(function()
                      attach_preset_notifier(device)
                    end)
                end

                coroutine.yield()
            end
        end, debug.traceback)
        if not ok then
            print("OVERSAMPLE enumerate_devices ERROR:\n" .. tostring(err))
        end
    end

    -- Count the parameters a device actually exposes by probing device:parameter(p)
    -- until it raises (the true end of the list). Used to validate cached lists,
    -- since the length operator ('#') can under-report the count for some VST3
    -- plugins. Declared before get_parameters because both call it.
    function devices.count_parameters(device)
        local n = 0
        local p = 1
        while p <= 4096 do
            local ok = pcall(function()
                return device:parameter(p)
            end)
            if not ok then
                break
            end
            n = n + 1
            p = p + 1
        end
        return n
    end

    function devices.get_parameters(device_name)
        local cached = state.cached_parameters[device_name]
        if cached then
            -- Reject a stale cache: empty, placeholder-only, or — most importantly —
            -- shorter than the plugin's current parameter count (a truncated list
            -- left behind by an interrupted scan, or by an under-reported #count on
            -- VST3 plugins). A full cache matches the live count exactly.
            local instances = devices.ensure_device_instances(device_name)
            local device = instances[1]
            if device and #cached == devices.count_parameters(device)
                and #cached > 0 and type(cached[1]) == "string"
                and not cached[1]:match("^%(parameter %d+%)$") then
                return cached
            end
            state.cached_parameters[device_name] = nil
        end

        local instances = devices.ensure_device_instances(device_name)
        local device = instances[1]
        if not device then
            -- Cannot reach into the plugin (e.g. scanned concurrently): bail out.
            return {}
        end

        -- Enumerate by probing device:parameter(p), instead of trusting
        -- #device.parameters (the length operator under-reports the count for some
        -- VST3 plugins). When device:parameter(p) raises (e.g. "invalid parameter
        -- index") we have reached the end of the plugin's exposed parameter list:
        -- stop. We must NOT fabricate placeholder entries for the thrown indices,
        -- because selecting one would crash and a gap would truncate ipairs().
        local parameters = {}
        local got_real = false
        local p = 1
        while p <= 4096 do
            local ok, parameter = pcall(function()
                return device:parameter(p)
            end)
            if not ok or not parameter then
                break
            end

            local name = parameter.name
            if name and name ~= "" then
                parameters[p] = name
                got_real = true
            else
                parameters[p] = ("(parameter %d)"):format(p)
            end

            p = p + 1
            -- Yield every few parameters so Renoise stays responsive during the
            -- (one-time) scan of plugins with very large parameter counts.
            if p % 8 == 0 then
                coroutine.yield()
            end
        end

        -- Cache the result so we never iterate this plugin's parameters again
        -- (until the device type is removed/re-added or its preset changes). The
        -- cache is kept both per-song (tool_data) and machine-wide (preferences),
        -- so the installed plugin is only ever reached into once. Only cache a
        -- non-empty enumeration; a partial or empty pass is retried the next time
        -- it is needed.
        if got_real then
            state.cached_parameters[device_name] = parameters
            state.cache_dirty = true
            state.global_cache_dirty = true
        end

        return parameters
    end

    function devices.enumerate_parameters(device_name)
        if state.dialog and state.dialog.visible and vb.views.set_values_button then
            set_main_buttons_active(false)
        end

        local parameters = devices.get_parameters(device_name)

        if state.dialog and state.dialog.visible and vb.views.set_values_button then
            set_main_buttons_active(true)
        end

        return parameters
    end

    return devices
end
