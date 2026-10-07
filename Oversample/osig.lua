-- Oversampling state-chunk signatures: dropdown labels/order and the VST3
-- chunk-patching fallback used when a plugin does not expose oversampling as a
-- host parameter.
--
-- Load-safe: Renoise, the core module, the shared state, and the device module
-- (for live instance resolution) are injected, so requiring this module never
-- touches the host at load time.
return function(deps)
    local renoise = deps.renoise
    local core = deps.core
    local state = deps.state
    local devices = deps.devices

    local osig = {}

    -- The natural, ascending oversampling labels for a device: from
    -- known_osig_order when defined, otherwise the distinct labels found in the
    -- learned `entries`, sorted alphabetically.
    local function osig_label_order(norm, entries)
        local known = core.osig_choices(norm)
        if known then
            local labels = {}
            for i, c in ipairs(known) do
                labels[i] = c.label
            end
            return labels
        end
        local seen = {}
        local labels = {}
        for _, e in ipairs(entries) do
            for lab in pairs(e.values) do
                if not seen[lab] then
                    seen[lab] = true
                    labels[#labels + 1] = lab
                end
            end
        end
        table.sort(labels)
        return labels
    end

    -- osig dropdown choices ({ label, value }) for a device, in natural order.
    function osig.osig_choices_for(norm, entries)
        local choices = {}
        for i, lab in ipairs(osig_label_order(norm, entries)) do
            choices[i] = { label = lab, value = i }
        end
        return choices
    end

    -- The separator used to combine a primary + dependent secondary label into a
    -- single osig target key (e.g. "Linear Phase / Maximum").
    osig.SECONDARY_SEP = " / "

    -- Split a combined "axis1 / axis2" osig label; a label without the separator
    -- yields the label itself and nil for the second axis.
    function osig.split_target_label(label)
        if type(label) ~= "string" then
            return label, nil
        end
        local sep = label:find(osig.SECONDARY_SEP, 1, true)
        if not sep then
            return label, nil
        end
        return label:sub(1, sep - 1), label:sub(sep + #osig.SECONDARY_SEP)
    end

    -- Combine two independent axis labels into a single osig target key; a missing
    -- or empty second axis leaves the primary label unchanged.
    function osig.join_target_label(axis1, axis2)
        if not axis2 or axis2 == "" then
            return axis1
        end
        return axis1 .. osig.SECONDARY_SEP .. axis2
    end

    -- Compute the combined osig target label for a row (primary, plus secondary when
    -- one is active). Returns nil for non-osig-driven rows.
    function osig.osig_target_for_row(row_number)
        local sd = state.selected_devices[row_number]
        if not sd or not sd.osig_driven then
            return nil
        end
        local primary = sd.osig_target_label
        local sec = sd.osig_target_label_sec
        if not sec then
            return primary
        end
        if not primary then
            return sec
        end
        -- A primary can itself be a combined label (e.g. Pro-Q 3's "Linear Phase / Medium");
        -- the dependent secondary replaces the trailing portion (the axis-1 value before the
        -- first " / "), so we never append a third segment that matches no signature label
        -- (e.g. "Linear Phase / Medium / High").
        local axis1 = osig.split_target_label(primary)
        return axis1 .. osig.SECONDARY_SEP .. sec
    end

    -- VST3 state-chunk fallback. When a device's oversampling is not exposed as a
    -- host parameter (so there is no parameter_index to drive) but a signature
    -- exists, flip the learned bytes directly in the plugin's raw
    -- 'active_preset_data' blob. Returns the number of device instances whose state
    -- chunk was actually changed; blobs already at the target are a successful
    -- no-op and are not counted.
    function osig.apply_osig_to_device_name(device_name, target, save_state)
        -- osig state-chunk signatures are VST3-only; applying them to an AU/VST2 build
        -- would patch the wrong bytes. Guard here as the last line of defense even though
        -- the UI only marks rows osig_driven for VST3 devices.
        if device_name:sub(1, 5) ~= "VST3:" then
            return 0
        end
        local norm = core.normalize_device_name(device_name)
        local entries = state.osig[norm]
        if not entries or #entries == 0 then
            return 0
        end
        -- Renoise caches a VST3 plugin's serialized state; refresh it from the live GUI
        -- (by saving first) so we patch the current state and never revert the user's
        -- other settings. Guarded so an unsaved song never triggers a save dialog.
        -- `save_state.saved` ensures the song is refreshed at most once across all osig
        -- rows applied in a single Set action.
        local song = renoise.song()
        if not save_state.saved and song.file_name and song.file_name ~= "" then
            pcall(function() song:save() end)
            save_state.saved = true
        end
        -- "toggle" resolves to a concrete label: detect the current value, then step to
        -- the next one in the device's natural oversampling order (cyclic). This keeps a
        -- single toggle button useful even though oversampling is now multi-valued.
        if target == "toggle" then
            local dev0 = devices.ensure_device_instances(device_name)[1]
            local cur = nil
            if dev0 then
                local ok, blob = pcall(function() return dev0.active_preset_data end)
                if ok and type(blob) == "string" and blob ~= "" then
                    if blob:match("<ParameterChunk>") then
                        cur = core.detect_label_xml(blob, entries)
                    else
                        cur = core.detect_label(blob, entries)
                    end
                end
            end
            -- Prefer the device's explicit oversampling order (e.g. 2x before 16x); only fall
            -- back to alphabetical sorting when no natural order is defined.
            local ordered = osig_label_order(norm, entries)
            if cur then
                for i, lab in ipairs(ordered) do
                    if lab == cur then
                        target = ordered[(i % #ordered) + 1]
                        break
                    end
                end
            else
                target = ordered[1]
            end
        end
        local instances = devices.ensure_device_instances(device_name)
        local changed = 0
        for _, dev in ipairs(instances) do
            local ok, xml = pcall(function() return dev.active_preset_data end)
            if ok and type(xml) == "string" and xml ~= "" then
                local is_xml = xml:match("<ParameterChunk>")
                -- Fail closed: only patch when the current chunk is a recognized oversampling
                -- state for this device. After a plugin update or with a stale signature the
                -- learned bytes no longer describe the real state, and writing the target would
                -- overwrite unrelated bytes; skipping keeps the device intact.
                local cur = is_xml and core.detect_label_xml(xml, entries) or core.detect_label(xml, entries)
                if not cur then
                    print("OVERSAMPLE osig apply skipped for '" .. tostring(device_name)
                        .. "': current state is not a recognized oversampling signature")
                else
                    local newdata
                    if is_xml then
                        -- patch_osig_xml returns nil only when the target bytes already match the
                        -- current state (no change needed — e.g. two oversampling labels that
                        -- serialize to identical chunks). That is a successful no-op, not an error.
                        newdata = core.patch_osig_xml(xml, entries, target)
                    else
                        newdata = core.patch_blob(xml, entries, target)
                    end
                    if newdata and newdata ~= xml then
                        local ok2, err = pcall(function()
                            dev.active_preset_data = newdata
                        end)
                        if ok2 then
                            changed = changed + 1
                        else
                            print("OVERSAMPLE osig apply failed for '"
                                .. tostring(device_name) .. "': " .. tostring(err))
                        end
                    end
                end
            end
        end
        return changed
    end

    -- Exposed for the tests that exercise the label helpers directly.
    osig.osig_label_order = osig_label_order

    return osig
end
