-- Single owner of the tool's mutable runtime state. Keeping it in one table
-- lets the extracted modules receive it through their factory deps instead of
-- each closing over its own module locals. Load-safe: Renoise is injected, so
-- requiring this module never touches the host at load time.
return function(renoise)
    local state = {
        -- Dialog + rendered-grid state.
        dialog = nil,
        devices = {},
        devices_valid = false,
        settings_row_count = 0,
        selected_devices = {},

        -- In-flight background parameter scans (ProcessSlicer workers).
        pending_parameter_scans = 0,
        device_scan_count = 0,
        device_scan_total = 0,

        -- In-memory mirrors of the persisted caches.
        cached_parameters = {},
        cached_device_names = {},
        osig = {},

        -- *_dirty flags mark what still needs persisting.
        cache_dirty = false,
        global_cache_dirty = false,
        device_names_dirty = false,
        global_device_names_dirty = false,

        initialized = false,
        parameter_choices_cache = {},

        -- Live notifier closures, so re-attaching removes the exact reference
        -- instead of leaving duplicate anonymous closures behind. Both keys
        -- (device userdata) and values (closures capturing their device) are
        -- weak: a strong value would keep a removed device's key reachable
        -- forever on Lua 5.1, since the closure captures the device. The song
        -- track-list notifier keeps the observable it was added to so it can be
        -- removed.
        device_preset_notifiers = setmetatable({}, { __mode = "kv" }),
        song_tracks_observable = nil,
        song_tracks_notifier = nil,
    }

    -- Combined per-song cache document, stored in renoise.song().tool_data (the
    -- portable copy that travels with the .xrns file).
    state.tool_cache_doc = renoise.Document.create("OversampleCache") {
        parameters = renoise.Document.ObservableStringList(),
        device_names = renoise.Document.ObservableStringList(),
        osig = renoise.Document.ObservableStringList()
    }

    return state
end
