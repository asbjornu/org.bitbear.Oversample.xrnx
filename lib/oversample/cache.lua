-- Persistent parameter/device/oversampling-signature cache.
--
-- Enumerating every parameter of every plugin is what made this tool slow.
-- Plugin parameter lists only change when a plugin is added or removed, so we
-- cache them and store the cache *inside the song file* via
-- renoise.song().tool_data. Renoise keeps this data slot when the song is
-- saved/reloaded (it is unique per tool bundle id), so the cache survives
-- across sessions and never has to be recomputed for already known plugins.
--
-- A per-device cache entry is stored as a length-prefixed, fully printable
-- string ("<len>;<value>" blocks concatenated). This survives Renoise's XML
-- serialization of renoise.song().tool_data without relying on delimiters
-- that device/parameter names might contain.
--
-- Load-safe: Renoise, the core module, and the shared state are injected, so
-- requiring this module never touches the host at load time.
return function(deps)
    local renoise = deps.renoise
    local core = deps.core
    local state = deps.state

    local cache = {}

    -- Count elements of a renoise.Document ObservableList. Observable lists expose
    -- their length through the :size() method; plain Lua tables (the in-memory
    -- mirrors and test doubles) fall back to a size field or the length operator.
    local function list_count(list)
        if type(list.size) == "function" then
            return list:size()
        end
        if list.size ~= nil then
            return list.size
        end
        return #list
    end

    -- Coerce a renoise.Document list element to a plain string. Document Node
    -- elements (userdata) can appear when stale/corrupt cached data is parsed, in
    -- which case we extract the node's text value (or skip it if unrecoverable).
    local function list_item_str(item)
        if type(item) == "string" then
            return item
        end
        if type(item) == "userdata" then
            local ok, v = pcall(function() return item.value end)
            if ok and type(v) == "string" then return v end
            local ok2, v2 = pcall(function() return item.text_value end)
            if ok2 and type(v2) == "string" then return v2 end
        end
        return nil
    end

    -- Merge one serialized cache list (a renoise.Document string list) into the
    -- in-memory parameter mirror. Per-song entries override machine-wide ones.
    local function merge_cache_list(list)
        for i = 1, list_count(list) do
            local item = list_item_str(list[i])
            if item then
                local fields = core.decode_fields(item)
                if #fields >= 2 then
                    local name = fields[1]
                    local params = {}
                    for p = 2, #fields do
                        params[p - 1] = fields[p]
                    end
                    state.cached_parameters[name] = params
                end
            end
        end
    end

    -- Merge a serialized name list, de-duplicating while preserving order. As with
    -- the other merge helpers, coerce each element through list_item_str so stale or
    -- corrupt document nodes are skipped instead of being serialized as
    -- "userdata: 0x...".
    local function merge_name_list(list)
        for i = 1, list_count(list) do
            local name = list_item_str(list[i])
            if name then
                local seen = false
                for _, v in ipairs(state.cached_device_names) do
                    if v == name then seen = true; break end
                end
                if not seen then state.cached_device_names[#state.cached_device_names + 1] = name end
            end
        end
    end

    -- Merge a serialized oversampling-signature list into the in-memory mirror. Each
    -- stored item encodes the device name followed by the encoded entries.
    local function merge_osig_list(list)
        for i = 1, list_count(list) do
            local item = list_item_str(list[i])
            if item then
                local fields = core.decode_fields(item)
                if #fields >= 2 then
                    local raw_name = fields[1]
                    -- The oversampling-signature patch route is VST3-only, and VST3 chunks are not
                    -- interchangeable with VST2/AU/CLAP/LV2/DX state. A persisted signature whose
                    -- name carries a *recognized host-format* prefix other than VST3 (e.g.
                    -- "VST: FabFilter: ...") must be discarded so it cannot normalize to the same
                    -- name as the VST3 entry and win the merge. Vendor names such as
                    -- "FabFilter: Pro-C 2" are NOT host prefixes: normalize_device_name leaves them
                    -- unchanged, so they (our own persisted VST3 signatures) are kept. VST3-prefixed
                    -- names are stripped to the same vendor name for lookup.
                    local norm = core.normalize_device_name(raw_name)
                    local has_host_prefix = (norm ~= raw_name)
                    if not has_host_prefix or raw_name:sub(1, 5) == "VST3:" then
                        local name = norm
                        local entries = core.decode_osig(fields[2])
                        if name and #entries > 0 then
                            state.osig[name] = entries
                        end
                    end
                end
            end
        end
    end

    -- Fill a renoise.Document string list with the current in-memory signatures.
    local function fill_osig_list(list)
        while list_count(list) > 0 do list:remove(1) end
        for name, entries in pairs(state.osig) do
            list:insert(core.encode_field(name) .. core.encode_field(core.encode_osig(entries)))
        end
    end

    -- Load both caches from the machine-wide preferences and the per-song tool_data.
    function cache.load_tool_cache()
        state.cached_parameters = {}
        state.cached_device_names = {}
        -- Rebuild the in-memory signature map from scratch so a signature learned from a
        -- previous song cannot leak into the next one (which would make Set patch unrelated
        -- bytes on a VST3 device). The machine-wide, per-song, and built-in entries are
        -- re-merged below in that order.
        for k in pairs(state.osig) do state.osig[k] = nil end
        -- Drop the per-song lists carried over in the reused document object. They are
        -- repopulated by from_string() when the current song has tool_data, and stay empty
        -- otherwise; clearing all three here (not just osig) prevents stale parameters and
        -- device names from a previous song leaking into the next when its tool_data is empty.
        while list_count(state.tool_cache_doc.osig) > 0 do state.tool_cache_doc.osig:remove(1) end
        while list_count(state.tool_cache_doc.parameters) > 0 do state.tool_cache_doc.parameters:remove(1) end
        while list_count(state.tool_cache_doc.device_names) > 0 do state.tool_cache_doc.device_names:remove(1) end

        -- Machine-wide (survives across songs and sessions).
        merge_cache_list(renoise.tool().preferences.cached_parameters)
        merge_name_list(renoise.tool().preferences.cached_device_names)
        merge_osig_list(renoise.tool().preferences.osig)

        -- Per-song (travels with the .xrns file; overrides machine-wide). The song may
        -- not exist yet while the tool is loaded at startup, before Renoise creates the
        -- initial song, so guard against a nil song here.
        local song = renoise.song()
        if song then
            local data = song.tool_data
            if data and data ~= "" then
                local ok, err = pcall(function()
                    state.tool_cache_doc:from_string(data)
                end)
                if not ok then
                    print('Oversample: failed to load cache: ' .. tostring(err))
                    while list_count(state.tool_cache_doc.parameters) > 0 do
                        state.tool_cache_doc.parameters:remove(1)
                    end
                    while list_count(state.tool_cache_doc.device_names) > 0 do
                        state.tool_cache_doc.device_names:remove(1)
                    end
                    while list_count(state.tool_cache_doc.osig) > 0 do
                        state.tool_cache_doc.osig:remove(1)
                    end
                end
            end
            pcall(function()
                merge_cache_list(state.tool_cache_doc.parameters)
                merge_name_list(state.tool_cache_doc.device_names)
                merge_osig_list(state.tool_cache_doc.osig)
            end)
        end

        -- Built-in signatures (learned offline from saved songs) are authoritative: they
        -- always override any stale cached signature (e.g. left over from the removed
        -- calibration flow) so a cached entry can never shadow a verified one.
        for name, entries in pairs(core.known_osig or {}) do
            state.osig[name] = entries
        end

        state.cache_dirty = false
        state.global_cache_dirty = false
        state.device_names_dirty = false
        state.global_device_names_dirty = false
    end

    -- Rebuild the combined per-song document and persist it to tool_data.
    function cache.save_tool_cache()
        while list_count(state.tool_cache_doc.parameters) > 0 do
            state.tool_cache_doc.parameters:remove(1)
        end
        for name, params in pairs(state.cached_parameters) do
            local entry = core.encode_field(name)
            for _, param in ipairs(params) do
                entry = entry .. core.encode_field(param)
            end
            state.tool_cache_doc.parameters:insert(entry)
        end

        while list_count(state.tool_cache_doc.device_names) > 0 do
            state.tool_cache_doc.device_names:remove(1)
        end
        for _, name in ipairs(state.cached_device_names) do
            state.tool_cache_doc.device_names:insert(name)
        end

        fill_osig_list(state.tool_cache_doc.osig)

        local ok, err = pcall(function()
            renoise.song().tool_data = state.tool_cache_doc:to_string()
        end)
        if not ok then
            print('Oversample: failed to save cache: ' .. tostring(err))
        else
            state.cache_dirty = false
            state.device_names_dirty = false
        end
    end

    -- Write the in-memory oversampling signatures into the machine-wide preferences.
    function cache.save_global_osig()
        fill_osig_list(renoise.tool().preferences.osig)
    end

    -- Write the in-memory parameter cache into the machine-wide preferences.
    function cache.save_global_cache()
        local list = renoise.tool().preferences.cached_parameters
        while list_count(list) > 0 do
            list:remove(1)
        end
        for name, params in pairs(state.cached_parameters) do
            local entry = core.encode_field(name)
            for _, param in ipairs(params) do
                entry = entry .. core.encode_field(param)
            end
            list:insert(entry)
        end
        cache.save_global_osig()
        state.global_cache_dirty = false
    end

    -- Write the in-memory device-name list into the machine-wide preferences.
    function cache.save_global_device_name_cache()
        local list = renoise.tool().preferences.cached_device_names
        while list_count(list) > 0 do
            list:remove(1)
        end
        for _, name in ipairs(state.cached_device_names) do
            list:insert(name)
        end
        state.global_device_names_dirty = false
    end

    -- Drop cache entries for device types that no longer exist in the song.
    -- Called whenever the song's device set changes (plugin added or removed).
    function cache.prune_parameter_cache()
        local song = renoise.song()
        local existing = {}

        for t = 1, list_count(song.tracks) do
            local track = song:track(t)
            for d = 1, list_count(track.devices) do
                existing[track:device(d).name] = true
            end
        end

        local changed = false
        for name, _ in pairs(state.cached_parameters) do
            if not existing[name] then
                state.cached_parameters[name] = nil
                changed = true
            end
        end

        if changed then
            state.cache_dirty = true
            state.global_cache_dirty = true
        end
    end

    -- Exposed for the tests that exercise the merge helpers directly.
    cache.list_count = list_count
    cache.list_item_str = list_item_str
    cache.merge_cache_list = merge_cache_list
    cache.merge_name_list = merge_name_list
    cache.merge_osig_list = merge_osig_list
    cache.fill_osig_list = fill_osig_list

    return cache
end
