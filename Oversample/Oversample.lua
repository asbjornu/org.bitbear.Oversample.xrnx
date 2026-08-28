-- Lua 5.2+ removed table.getn; use a local alias for compatibility.
local getn = table.getn or function(t) return #t end

-- Pure, Renoise-independent helpers live in the shared core module so they can be
-- unit-tested in isolation. Alias them here to keep the call sites below unchanged.
local core = require("Oversample/oversample_core")
local known_devices_parameters = core.known_devices_parameters
local encode_field = core.encode_field
local decode_fields = core.decode_fields
local match_parameter = core.match_parameter
local known_primary = core.known_primary
local known_secondary = core.known_secondary
local nearest_choice_index = core.nearest_choice_index
local same_name_set = core.same_name_set

local vb = renoise.ViewBuilder()
local DEFAULT_DIALOG_MARGIN = renoise.ViewBuilder.DEFAULT_DIALOG_MARGIN
local DEFAULT_CONTROL_SPACING = renoise.ViewBuilder.DEFAULT_CONTROL_SPACING
local CONTENT_MARGIN = renoise.ViewBuilder.DEFAULT_CONTROL_MARGIN
local CONTENT_HEIGHT = renoise.ViewBuilder.DEFAULT_CONTROL_HEIGHT
local COLUMN_WIDTH = 16 * CONTENT_HEIGHT
local HALF_COLUMN_WIDTH = 8 * CONTENT_HEIGHT
local dialog = nil
local devices = {}
local devices_valid = false
local settings_row_count = 0
-- The dialog historically called this with no argument, meaning "the current row
-- count". The pure core builder requires a row number, so supply the default here.
local function create_settings_row_identifiers(row_number)
   return core.create_settings_row_identifiers(row_number or settings_row_count)
end
local selected_devices = {}

-- Tracks in-flight per-device parameter scans so the status text only reports
-- "Done." once every background scan has actually finished (each row's default
-- device triggers its own asynchronous enumeration via ProcessSlicer).
local pending_parameter_scans = 0
local device_scan_count = 0
local device_scan_total = 0
local function mark_parameter_scan_started()
    pending_parameter_scans = pending_parameter_scans + 1
    vb.views.status.text = string.format('Finding parameters... (%d)', pending_parameter_scans)
end
local function mark_parameter_scan_finished()
    if (pending_parameter_scans > 0) then
        pending_parameter_scans = pending_parameter_scans - 1
    end
    if (pending_parameter_scans == 0) then
        vb.views.status.text = 'Done.'
    else
        vb.views.status.text = string.format('Finding parameters... (%d)', pending_parameter_scans)
    end
end

-- known_devices_parameters is provided by the core module (see oversample_core.lua).


-------------------------------------------------------------------------------
-- Persistent parameter cache
--
-- Enumerating every parameter of every plugin is what made this tool slow.
-- Plugin parameter lists only change when a plugin is added or removed, so we
-- cache them and store the cache *inside the song file* via
-- renoise.song().tool_data. Renoise keeps this data slot when the song is
-- saved/reloaded (it is unique per tool bundle id), so the cache survives
-- across sessions and never has to be recomputed for already known plugins.
-------------------------------------------------------------------------------

-- A per-device cache entry is stored as a length-prefixed, fully printable
-- string ("<len>;<value>" blocks concatenated). This survives Renoise's XML
-- serialization of renoise.song().tool_data without relying on delimiters
-- that device/parameter names might contain.
-- encode_field / decode_fields are provided by the core module.

-- In-memory mirror of the cache: [device_name] -> { parameter_name, ... }
local cached_parameters = {}

-- In-memory, ordered list of device names discovered in the current song.
-- Persisted (per-song and machine-wide) so the device dropdown can be shown
-- instantly on open without re-walking every track/device in the project.
local cached_device_names = {}

-- Combined per-song cache document, stored in renoise.song().tool_data (the
-- portable copy that travels with the .xrns file).
local tool_cache_doc = renoise.Document.create("OversampleCache") {
  parameters = renoise.Document.ObservableStringList(),
  device_names = renoise.Document.ObservableStringList()
}

-- *_dirty flags mark what still needs persisting.
local cache_dirty = false
local global_cache_dirty = false
local device_names_dirty = false
local global_device_names_dirty = false

-- Count elements of a renoise.Document list, robust to size being a property
-- or a function depending on the API version.
local function list_count(list)
  local n = list.size
  if (type(n) == "function") then
    n = list:size()
  end
  return n
end

-- Merge one serialized cache list (a renoise.Document string list) into the
-- in-memory parameter mirror. Per-song entries override machine-wide ones.
local function merge_cache_list(list)
  for i = 1, list_count(list) do
    local fields = decode_fields(list[i])
    if (#fields >= 2) then
      local name = fields[1]
      local params = {}
      for p = 2, #fields do
        params[p - 1] = fields[p]
      end
      cached_parameters[name] = params
    end
  end
end

-- Merge a serialized name list, de-duplicating while preserving order.
local function merge_name_list(list)
  for i = 1, list_count(list) do
    local name = tostring(list[i])
    local seen = false
    for _, v in ipairs(cached_device_names) do
      if (v == name) then seen = true; break end
    end
    if (not seen) then cached_device_names[#cached_device_names + 1] = name end
  end
end

-- Load both caches from the machine-wide preferences and the per-song tool_data.
function load_tool_cache()
  cached_parameters = {}
  cached_device_names = {}

  -- Machine-wide (survives across songs and sessions).
  merge_cache_list(renoise.tool().preferences.cached_parameters)
  merge_name_list(renoise.tool().preferences.cached_device_names)

  -- Per-song (travels with the .xrns file; overrides machine-wide). The song may
  -- not exist yet while the tool is loaded at startup, before Renoise creates the
  -- initial song, so guard against a nil song here.
  local song = renoise.song()
  if (song) then
    local data = song.tool_data
    if (data and data ~= "") then
      local ok, err = pcall(function()
        tool_cache_doc:from_string(data)
      end)
      if (not ok) then
        print('Oversample: failed to load cache: ' .. tostring(err))
        while (list_count(tool_cache_doc.parameters) > 0) do
          tool_cache_doc.parameters:remove(1)
        end
        while (list_count(tool_cache_doc.device_names) > 0) do
          tool_cache_doc.device_names:remove(1)
        end
      end
    end
    merge_cache_list(tool_cache_doc.parameters)
    merge_name_list(tool_cache_doc.device_names)
  end

  cache_dirty = false
  global_cache_dirty = false
  device_names_dirty = false
  global_device_names_dirty = false
end

-- Rebuild the combined per-song document and persist it to tool_data.
function save_tool_cache()
  while (list_count(tool_cache_doc.parameters) > 0) do
    tool_cache_doc.parameters:remove(1)
  end
  for name, params in pairs(cached_parameters) do
    local entry = encode_field(name)
    for _, param in ipairs(params) do
      entry = entry .. encode_field(param)
    end
    tool_cache_doc.parameters:insert(entry)
  end

  while (list_count(tool_cache_doc.device_names) > 0) do
    tool_cache_doc.device_names:remove(1)
  end
  for _, name in ipairs(cached_device_names) do
    tool_cache_doc.device_names:insert(name)
  end

  local ok, err = pcall(function()
    renoise.song().tool_data = tool_cache_doc:to_string()
  end)
  if (not ok) then
    print('Oversample: failed to save cache: ' .. tostring(err))
  else
    cache_dirty = false
    device_names_dirty = false
  end
end

-- Write the in-memory parameter cache into the machine-wide preferences.
function save_global_cache()
  local list = renoise.tool().preferences.cached_parameters
  while (list_count(list) > 0) do
    list:remove(1)
  end
  for name, params in pairs(cached_parameters) do
    local entry = encode_field(name)
    for _, param in ipairs(params) do
      entry = entry .. encode_field(param)
    end
    list:insert(entry)
  end
  global_cache_dirty = false
end

-- Write the in-memory device-name list into the machine-wide preferences.
function save_global_device_name_cache()
  local list = renoise.tool().preferences.cached_device_names
  while (list_count(list) > 0) do
    list:remove(1)
  end
  for _, name in ipairs(cached_device_names) do
    list:insert(name)
  end
  global_device_names_dirty = false
end

-- Drop cache entries for device types that no longer exist in the song.
-- Called whenever the song's device set changes (plugin added or removed).
function prune_parameter_cache()
  local song = renoise.song()
  local existing = {}

  for t = 1, getn(song.tracks) do
    local track = song:track(t)
    for d = 1, getn(track.devices) do
      existing[track:device(d).name] = true
    end
  end

  local changed = false
  for name, _ in pairs(cached_parameters) do
    if (not existing[name]) then
      cached_parameters[name] = nil
      changed = true
    end
  end

  if (changed) then
    cache_dirty = true
    global_cache_dirty = true
  end
end

-- The ordered list of device names currently in the song (tight loop, no
-- per-device yields). Used to refresh the persisted name list and to reconcile
-- the cache against the live song on open.
local function collect_device_names()
  local names = {}
  local seen = {}
  local song = renoise.song()
  local total_instances = 0
  local active_instances = 0
  local deduped = 0
  for t = 1, getn(song.tracks) do
    local track = song:track(t)
    for d = 1, getn(track.devices) do
      local device = track:device(d)
      total_instances = total_instances + 1
      if (device.is_active) then
        active_instances = active_instances + 1
      end
      if (device.is_active and not seen[device.name]) then
        seen[device.name] = true
        names[#names + 1] = device.name
      elseif (device.is_active and seen[device.name]) then
        deduped = deduped + 1
      end
    end
  end
  return names
end

-- same_name_set is provided by the core module.

-- Lazily resolve the live device instances for a device name. The full device
-- scan collects these once; afterwards we reuse the cached map, and if a name
-- is needed before that scan has run we walk the song directly (and wire up the
-- preset-change notifier so the parameter cache still invalidates).
local function ensure_device_instances(device_name)
  local entry = devices[device_name]
  if (entry and entry["instances"] and #entry["instances"] > 0) then
    return entry["instances"]
  end

  local instances = {}
  local song = renoise.song()
  for t = 1, getn(song.tracks) do
    local track = song:track(t)
    for d = 1, getn(track.devices) do
      local device = track:device(d)
      if (device.is_active and device.name == device_name) then
        instances[#instances + 1] = device
        pcall(function()
          device.active_preset_observable:remove_notifier(on_device_preset_changed)
          device.active_preset_observable:add_notifier(function()
            on_device_preset_changed(device)
          end)
        end)
      end
    end
  end

  if (not devices[device_name]) then devices[device_name] = {} end
  devices[device_name]["instances"] = instances
  return instances
end

local on_song_devices_changed = function()
  prune_parameter_cache()
  devices_valid = false
  cached_device_names = collect_device_names()
  device_names_dirty = true
  global_device_names_dirty = true
  save_global_device_name_cache()
end

-- A plugin's parameter list can change when its preset/program changes (some
-- plugins expose a different set of parameters per preset). When that happens
-- we drop the cached list so it is recomputed the next time it is needed.
function on_device_preset_changed(device)
  local name = device.name
  if (cached_parameters[name]) then
    print('Oversample: preset changed for "' .. name .. '", invalidating cache.')
    cached_parameters[name] = nil
    cache_dirty = true
    global_cache_dirty = true
  end
end

-- Watch every track's device list (and the track list itself) so that adding
-- or removing a plugin invalidates the cache for the affected device types.
local function attach_song_device_notifiers()
  local song = renoise.song()

  local function attach_track(track)
    pcall(function()
      track.devices_observable:remove_notifier(on_song_devices_changed)
    end)
    track.devices_observable:add_notifier(on_song_devices_changed)
  end

  for t = 1, getn(song.tracks) do
    attach_track(song:track(t))
  end

  song.tracks_observable:add_notifier(function()
    for t = 1, getn(song.tracks) do
      attach_track(song:track(t))
    end
    prune_parameter_cache()
    devices_valid = false
    cached_device_names = collect_device_names()
    device_names_dirty = true
    global_device_names_dirty = true
    save_global_device_name_cache()
  end)
end

-- Reset all per-song state when a new song is loaded, then reload the cache.
function oversample_on_new_song()
  devices = {}
  selected_devices = {}
  settings_row_count = 0
  devices_valid = false

  load_tool_cache()
  attach_song_device_notifiers()
end

local initialized = false

-- Called once from main.lua when the tool is loaded.
function oversample_init()
  if (initialized) then
    return
  end
  initialized = true

  load_tool_cache()

  -- The device notifiers need a live song, which may not exist yet while the tool
  -- is being loaded at Renoise startup (before the initial song is created). Defer
  -- them (and the per-song cache load) until a song is available.
  local function init_song_dependencies()
    load_tool_cache()
    attach_song_device_notifiers()
  end

  if (renoise.song()) then
    init_song_dependencies()
  else
    local idle_notifier
    idle_notifier = function()
      if (renoise.song()) then
        init_song_dependencies()
        renoise.tool().app_idle_observable:remove_notifier(idle_notifier)
      end
    end
    renoise.tool().app_idle_observable:add_notifier(idle_notifier)
  end

  -- Persist the cache right before the song is saved, but only when something
  -- actually changed. The global (preferences) copy travels with the tool
  -- install; the per-song copy travels with the .xrns file.
  renoise.tool().app_will_save_document_observable:add_notifier(function()
    if (cache_dirty or device_names_dirty) then
      save_tool_cache()
    end
    if (global_cache_dirty) then
      save_global_cache()
    end
    if (global_device_names_dirty) then
      save_global_device_name_cache()
    end
  end)

  renoise.tool().app_new_document_observable:add_notifier(oversample_on_new_song)
end

function oversample()
    if (dialog) then
        destroy()
    end

    pending_parameter_scans = 0

    local oversample = vb:row {
        id = "org.bitbear.Oversample",
        margin = CONTENT_MARGIN,
        vb:column {
            vb:row {
                vb:text {
                    text = "Device",
                    width = COLUMN_WIDTH
                },
                vb:text {
                    text = "Parameter",
                    width = COLUMN_WIDTH
                },
                vb:text {
                    text = "Value",
                    width = HALF_COLUMN_WIDTH
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
                vb:row {
                    vb:button {
                        id = "minimize_values_button",
                        text = "Minimize",
                        width = HALF_COLUMN_WIDTH,
                        active = false,
                        notifier = function()
                            extreme_values("min")
                        end
                    },
                    vb:button {
                        id = "maximize_values_button",
                        text = "Maximize",
                        width = HALF_COLUMN_WIDTH,
                        active = false,
                        notifier = function()
                            extreme_values("max")
                        end
                    },
                    vb:button {
                        id = "set_values_button",
                        text = "Set",
                        width = HALF_COLUMN_WIDTH,
                        color = { 165, 73, 35 },
                        active = false,
                        notifier = set_values
                    }
                }
            }
        }
    }

    dialog = renoise.app():show_custom_dialog("Oversample", oversample)

    if (devices_valid) then
        -- In-session cache (instances already collected): rebuild instantly.
        add_device_items_init()
        return
    end

    local live_names = collect_device_names()
    if (#cached_device_names > 0 and same_name_set(cached_device_names, live_names)) then
        -- Reconciled with the live song: show the cached device list now and
        -- resolve the (cheap) live instances lazily when the user interacts.
        cached_device_names = live_names
        devices_valid = true
        render_settings_rows(live_names)
        -- Per-row parameter scans may still be running in the background.
        if (pending_parameter_scans == 0) then
            vb.views.status.text = 'Done.'
        end
        return
    end

    -- Names unavailable or out of date: run the one-time scan to collect live
    -- instances and reconcile against the persisted list.
    vb.views.status.text = 'Finding devices...'

    devices = {}
    selected_devices = {}
    settings_row_count = 0

    local slicer = ProcessSlicer(enumerate_tracks, add_device_items_init)
    slicer:start()
end

function destroy()
    if (dialog) then
        pcall(function() dialog:close() end)
    end
    dialog = nil

    -- Unregister the per-row views explicitly: the viewbuilder keeps a flat
    -- id registry, so without this the fixed ids (devices_popup_1, ...) would
    -- collide when the dialog is rebuilt on the next open.
    for i = 1, settings_row_count do
        local ids = create_settings_row_identifiers(i)
        vb.views[ids["device_popup_id"]] = nil
        vb.views[ids["parameter_popup_id"]] = nil
        vb.views[ids["parameter_value_popup_id"]] = nil
        vb.views[ids["parameter_value_slider_id"]] = nil
        vb.views[ids["parameter_value_secondary_popup_id"]] = nil
        vb.views[ids["settings_row_id"]] = nil
        vb.views[ids["add_button_id"]] = nil
    end

    vb.views["set_values_button"] = nil
    vb.views["minimize_values_button"] = nil
    vb.views["maximize_values_button"] = nil
    vb.views["status"] = nil
    vb.views["settings_container"] = nil
    vb.views["org.bitbear.Oversample"] = nil
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

    local device_popup_id = settings_row_identifiers["device_popup_id"]
    local parameter_popup_id = settings_row_identifiers["parameter_popup_id"]
    local parameter_value_popup_id = settings_row_identifiers["parameter_value_popup_id"]
    local parameter_value_slider_id = settings_row_identifiers["parameter_value_slider_id"]
    local parameter_value_secondary_popup_id = settings_row_identifiers["parameter_value_secondary_popup_id"]
    local settings_row_id = settings_row_identifiers["settings_row_id"]
    local add_button_id = settings_row_identifiers["add_button_id"]

    return vb:row {
        id = settings_row_id,
        vb:popup {
            id = device_popup_id,
            width = COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                local device_name = vb.views[device_popup_id].items[value]
                device_selected(value, device_name, parameter_popup_id, row_number)
            end,
        },
        vb:popup {
            id = parameter_popup_id,
            width = COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                local parameter_name = vb.views[parameter_popup_id].items[value]
                local device_popup = vb.views[device_popup_id]
                local selected_device_index = device_popup.value
                local device_name = device_popup.items[selected_device_index]
                parameter_selected(value, parameter_name, device_name, row_number)
            end,
        },
        vb:popup {
            id = parameter_value_popup_id,
            width = HALF_COLUMN_WIDTH,
            active = false,
            visible = false,
            notifier = function(value)
                local ids = create_settings_row_identifiers(row_number)
                local popup = vb.views[ids["parameter_value_popup_id"]]
                local device_popup = vb.views[device_popup_id]
                local device_name = device_popup.items[device_popup.value]
                local device_instances = ensure_device_instances(device_name)
                if (not device_instances[1]) then
                    return
                end
                local choices = selected_devices[row_number]["parameter_choices"]
                local v
                if (choices and choices[value]) then
                    v = choices[value].value
                end
                if (v ~= nil) then
                    selected_devices[row_number]["parameter_value"] = v
                end
                update_secondary(row_number, device_name, device_instances)
            end,
        },
        vb:slider {
            id = parameter_value_slider_id,
            width = HALF_COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                local parameter_value = value
                local parameter_name = selected_devices[row_number]["parameter_name"]
                local device_popup = vb.views[device_popup_id]
                local device_name = device_popup.items[device_popup.value]
                parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
            end,
        },
        vb:popup {
            id = parameter_value_secondary_popup_id,
            width = HALF_COLUMN_WIDTH,
            active = false,
            visible = false,
            notifier = function(value)
                local ids = create_settings_row_identifiers(row_number)
                local spopup = vb.views[ids["parameter_value_secondary_popup_id"]]
                local device_popup = vb.views[device_popup_id]
                local device_name = device_popup.items[device_popup.value]
                local device_instances = ensure_device_instances(device_name)
                if (not device_instances[1]) then
                    return
                end
                local sec_index = selected_devices[row_number]["secondary_parameter_index"]
                if (sec_index) then
                    local choices = selected_devices[row_number]["secondary_parameter_choices"]
                    local v
                    if (choices and choices[value]) then
                        v = choices[value].value
                    end
                    if (v ~= nil) then
                        selected_devices[row_number]["secondary_parameter_value"] = v
                    end
                end
            end,
        },
        vb:button {
            id = add_button_id,
            text = "+",
            width = 16,
            notifier = function()
                local settings_row = create_settings_row()
                vb.views.settings_container:add_child(settings_row)
                local new_settings_row_identifiers = create_settings_row_identifiers()
                local device_popup_id = new_settings_row_identifiers["device_popup_id"]
                add_device_items(device_popup_id)
            end,
        }
    }
end

-- create_settings_row_identifiers is provided by the core module.

function render_settings_rows(device_names)
    local container = vb.views.settings_container
    settings_row_count = 0

    local sorted_names = {}
    for _, n in ipairs(device_names) do
        sorted_names[#sorted_names + 1] = n
    end
    table.sort(sorted_names)
    device_names = sorted_names

    local found = false
    for _, device_name in ipairs(device_names) do
        if (known_devices_parameters[device_name]) then
            found = true
            local settings_row = create_settings_row()
            container:add_child(settings_row)
            local settings_row_identifiers = create_settings_row_identifiers()
            local device_popup_id = settings_row_identifiers["device_popup_id"]

            local idx = 1
            for i, n in ipairs(device_names) do
                if (n == device_name) then
                    idx = i
                    break
                end
            end

            if (vb.views[device_popup_id]) then
                local devices_popup = vb.views[device_popup_id]
                devices_popup.items = device_names
                devices_popup.value = idx
                devices_popup.active = true
            end
        end
    end

    if (not found) then
        local settings_row = create_settings_row()
        container:add_child(settings_row)
        local settings_row_identifiers = create_settings_row_identifiers()
        local device_popup_id = settings_row_identifiers["device_popup_id"]
        if (vb.views[device_popup_id]) then
            local devices_popup = vb.views[device_popup_id]
            devices_popup.items = device_names
            devices_popup.active = true
        end
    end

    set_main_buttons_active(true)
end

function add_device_items_init()
    local ok, err = xpcall(function()
        devices_valid = true

        local device_items = {}
        if (next(devices) ~= nil) then
            for k, _ in pairs(devices) do
                device_items[#device_items + 1] = k
            end
        else
            for _, n in ipairs(cached_device_names) do
                device_items[#device_items + 1] = n
            end
        end

        table.sort(device_items)

        cached_device_names = device_items
        save_global_device_name_cache()

        render_settings_rows(device_items)

        -- Per-row parameter scans may still be running in the background.
        if (pending_parameter_scans == 0) then
            vb.views.status.text = 'Done.'
        end
    end, debug.traceback)
    if (not ok) then
        print("OVERSAMPLE add_device_items_init ERROR:\n" .. tostring(err))
    end
end

function add_device_items(device_popup_id, selected_device_index)
    local device_items = {}
    set_main_buttons_active(false)

    if (next(devices) ~= nil) then
        for k, _ in pairs(devices) do
            device_items[#device_items + 1] = k
        end
    else
        for _, n in ipairs(cached_device_names) do
            device_items[#device_items + 1] = n
        end
    end

    table.sort(device_items)

    if (vb.views[device_popup_id]) then
        local devices_popup = vb.views[device_popup_id]
        devices_popup.items = device_items
        devices_popup.active = true
        if (selected_device_index) then
            devices_popup.value = selected_device_index
        end
    else
        print('Could not add items to "' .. device_popup_id .. '" as it does not exist.')
    end

    set_main_buttons_active(true)
    -- A parameter scan may still be running in the background.
    if (pending_parameter_scans == 0) then
        vb.views.status.text = 'Done.'
    end
end

-- Set the value slider's range/current value from a resolved parameter index.
-- A parameter is treated as an enum (dropdown) when it exposes a small set of
-- named, distinct values. Some plugins report the steps with value_quantum == 1
-- (the easy case); others expose enums over a normalised range whose
-- value_quantum is fractional, in which case we check whether the endpoint
-- values map to real (non-numeric) names like "Zero Latency" / "Linear Phase".
-- A parameter is an enum when it exposes a small number of discrete, named
-- values. We detect this without mutating the plugin: a finite step count
-- (value_quantum-based) AND a non-numeric label for the current value.
-- A parameter is treated as an enum (dropdown) when it exposes a small number
-- of distinct, named values. Renoise does not expose enum labels directly, and
-- some enums report value_quantum == 0 (so the step count is unavailable), so
-- we enumerate the distinct labels by stepping the value and reading back the
-- snapped true value. A parameter with 2..64 distinct labels is an enum; one
-- with more (a continuous parameter) is a slider. The result is cached.
local parameter_choices_cache = {}

local function parameter_choices(parameter)
    local min_v = parameter.value_min
    local max_v = parameter.value_max
    local q = parameter.value_quantum

    local cache_key
    if (q and q > 0) then
        cache_key = parameter.name .. "\0" .. min_v .. "\0" .. max_v .. "\0" .. q
    else
        cache_key = parameter.name .. "\0" .. min_v .. "\0" .. max_v .. "\0q0"
    end
    if (parameter_choices_cache[cache_key]) then
        return parameter_choices_cache[cache_key]
    end

    local probe
    if (q and q > 0) then
        probe = math.floor((max_v - min_v) / q + 0.5)
        if (probe < 2) then
            probe = 2
        end
        if (probe > 256) then
            probe = 256
        end
    else
        -- value_quantum == 0: scan at a fixed resolution to discover the
        -- discrete labels. 128 probes is enough to capture the steps of any
        -- reasonable enum while staying cheap.
        probe = 128
    end

    local original = parameter.value
    local choices = {}
    local seen = {}
    for k = 0, probe do
        local v
        if (q and q > 0) then
            v = min_v + k * q
        else
            v = min_v + (max_v - min_v) * (k / probe)
        end
        local ok, s, tv = pcall(function()
            parameter.value = v
            return parameter.value_string, parameter.value
        end)
        if (ok and type(s) == "string") then
            local label = s:match("^%s*(.-)%s*$")
            if (label ~= "" and not seen[label]) then
                seen[label] = true
                choices[#choices + 1] = { value = tv, label = label }
            end
        end
    end
    pcall(function()
        parameter.value = original
    end)
    parameter_choices_cache[cache_key] = choices
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
function update_secondary(row_number, device_name, device_instances)
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids["parameter_value_secondary_popup_id"]]
    local sec_name = known_secondary(device_name)
    local primary_name = known_primary(device_name)

    local function hide_secondary()
        sec_popup.visible = false
        selected_devices[row_number]["secondary_parameter_index"] = nil
        selected_devices[row_number]["secondary_parameter_value"] = nil
        selected_devices[row_number]["secondary_parameter_name"] = nil
    end

    if (not sec_name or not primary_name) then
        hide_secondary()
        return
    end
    if (selected_devices[row_number]["parameter_name"] ~= primary_name) then
        hide_secondary()
        return
    end

    local device = device_instances[1]
    local primary_index = selected_devices[row_number]["parameter_index"]
    if (not primary_index or not device) then
        hide_secondary()
        return
    end
    local primary_param = device:parameter(primary_index)
    -- Use the intended value (what the user picked in the dropdown), not the
    -- plugin's possibly-stale live value, so the secondary appears as soon as
    -- "Linear Phase" is selected rather than only after "Set" is applied.
    local intended_value = selected_devices[row_number]["parameter_value"]
    if (intended_value == nil) then
        intended_value = primary_param.value
    end

    local pchoices = parameter_choices(primary_param)
    local primary_label
    if (#pchoices > 0) then
        primary_label = pchoices[nearest_choice_index(pchoices, intended_value)].label
    end

    if (not primary_label or not loose_eq(primary_label, SECONDARY_SHOW_WHEN)) then
        hide_secondary()
        return
    end

    local names = {}
    local count = count_parameters(device)
    for p = 1, count do
        names[p] = device:parameter(p).name
    end
    local sec_index = match_parameter(names, sec_name)
    if (not sec_index) then
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
    selected_devices[row_number]["secondary_parameter_index"] = sec_index
    selected_devices[row_number]["secondary_parameter_name"] = sec_param.name
    selected_devices[row_number]["secondary_parameter_value"] = sec_param.value
    selected_devices[row_number]["secondary_parameter_choices"] = sec_choices
end

-- Populate the value control (dropdown for enums, slider otherwise) for the
-- chosen parameter, and refresh any dependent secondary control.
-- Populate the value control (dropdown for enums, slider otherwise) for the
-- chosen parameter using an explicit target value, and refresh any dependent
-- secondary control. Used both when reflecting a live device value and when
-- previewing an extreme (min/max) value in the UI without touching the device.
local function apply_value_to_control(row_number, device_name, device_instances, parameter_index, target_value)
    local device = device_instances[1]
    local parameter = device:parameter(parameter_index)
    local ids = create_settings_row_identifiers(row_number)
    local popup = vb.views[ids["parameter_value_popup_id"]]
    local slider = vb.views[ids["parameter_value_slider_id"]]

    selected_devices[row_number]["parameter_index"] = parameter_index
    selected_devices[row_number]["parameter_name"] = parameter.name
    selected_devices[row_number]["parameter_value"] = target_value

    if (is_parameter_enum(parameter)) then
        local choices = parameter_choices(parameter)
        local labels = {}
        for i, c in ipairs(choices) do
            labels[i] = c.label
        end
        local idx = nearest_choice_index(choices, target_value)
        popup.items = labels
        popup.value = idx
        popup.active = true
        popup.visible = true
        slider.visible = false
        selected_devices[row_number]["parameter_choices"] = choices
    else
        slider.min = parameter.value_min
        slider.max = parameter.value_max
        slider.value = target_value
        slider.active = true
        slider.visible = true
        popup.visible = false
        selected_devices[row_number]["parameter_choices"] = nil
    end

    update_secondary(row_number, device_name, device_instances)
end

-- Reflect a device's current parameter value in the UI (the default behaviour
-- used after scans and after "Set" is applied).
local function set_value_control(row_number, device_name, device_instances, parameter_index)
    local device = device_instances[1]
    local parameter = device:parameter(parameter_index)
    apply_value_to_control(row_number, device_name, device_instances, parameter_index, parameter.value)
end

-- Update the value slider for a chosen parameter without scanning the whole
-- plugin: find the parameter by name in a single tight pass (no coroutine
-- yields) and read its current value directly. This lets the "Oversample"
-- parameter's slider react instantly, before the full list is enumerated.
local function apply_parameter_value(row_number, device_name, parameter_name)
    local device_instances = ensure_device_instances(device_name)
    local device = device_instances[1]
    if (not device) then
        return
    end

    local count = count_parameters(device)
    local names = {}
    for p = 1, count do
        names[p] = device:parameter(p).name
    end

    local parameter_index = match_parameter(names, parameter_name)
    if (not parameter_index) then
        return
    end

    selected_devices[row_number]["parameter_name"] = device:parameter(parameter_index).name
    selected_devices[row_number]["parameter_index"] = parameter_index
    set_value_control(row_number, device_name, device_instances, parameter_index)
end

function device_selected(device_index, device_name, parameter_popup_id, row_number)
    set_main_buttons_active(false)
    selected_devices[row_number] = {
         ["device_name"] = device_name,
         ["device_index"] = device_index
    }
    -- print('device_selected')

    local known_primary_name = known_primary(device_name)
    local parameters_popup = vb.views[parameter_popup_id]

    -- Populate the parameter dropdown from the (already known) full list, then
    -- snap to the recognised "Oversample" parameter. No waiting required.
    local function apply_parameters(parameters)
        if (not parameters) then
            parameters = {}
        end

        -- Only touch the UI while the Oversample dialog (and this row's popup)
        -- still exist. The scan may finish after the dialog was closed, in which
        -- case we keep the cached result but skip the visual update.
        if (not dialog or not dialog.visible or not parameters_popup) then
            return
        end

        -- If the enumeration produced no usable names (e.g. the plugin's editor
        -- was closed and it exposed nothing), keep whatever is already shown
        -- (the pre-filled known parameter) instead of replacing it with
        -- placeholders.
        local has_real = false
        for _, n in ipairs(parameters) do
            if (type(n) == "string" and not n:match("^%(parameter %d+%)$")) then
                has_real = true
                break
            end
        end
        if (not has_real) then
            return
        end

        parameters_popup.items = parameters
        parameters_popup.active = true

        if (known_primary_name) then
            local i = match_parameter(parameters, known_primary_name)
            if (i) then
                parameters_popup.value = i
            end
        end

        mark_parameter_scan_finished()
        set_main_buttons_active(true)
    end

    if (cached_parameters[device_name]) then
        -- Already cached (this session, song, or a previous run): no scan.
        apply_parameters(cached_parameters[device_name])
        if (known_primary_name) then
            apply_parameter_value(row_number, device_name, known_primary_name)
        end
        return
    end

    -- Not cached yet: show the recognised parameter(s) immediately so the user
    -- can act at once, then run the one-time scan to back-fill the rest.
    if (known_primary_name) then
        local items = { known_primary_name }
        parameters_popup.items = items
        parameters_popup.value = 1
        parameters_popup.active = true
        -- Reflect the known parameter's current value on the slider right away,
        -- without waiting for the full parameter scan to complete.
        apply_parameter_value(row_number, device_name, known_primary_name)
        set_main_buttons_active(true)
    else
        vb.views.status.text = 'Finding parameters...'
    end

    mark_parameter_scan_started()
    local slicer = ProcessSlicer(enumerate_parameters, function(return_value)
        apply_parameters(return_value[1])
    end, device_name)

    -- print('enumerate_devices:ProcessSlicer:start')
    slicer:start()
end

-- Set the value slider's range/current value from a resolved parameter index.
function parameter_selected(parameter_index, parameter_name, device_name, row_number)
    local device_instances = ensure_device_instances(device_name)
    selected_devices[row_number]["parameter_name"] = parameter_name
    selected_devices[row_number]["parameter_index"] = parameter_index

    for k, v in ipairs(device_instances) do
        set_main_buttons_active(false)
        set_value_control(row_number, device_name, device_instances, parameter_index)
    end

    set_main_buttons_active(true)
end

function parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
    selected_devices[row_number]["parameter_value"] = parameter_value
end

function enumerate_tracks()
    local ok, err = xpcall(function()
        -- print('enumerate_tracks')
        local song = renoise.song()

        -- Count the total number of active devices up front so the scan can show
        -- "Scanning devices… (k/total)" progress instead of flickering names.
        device_scan_total = 0
        device_scan_count = 0
        for t = 1, getn(song.tracks) do
            local track = song:track(t)
            for d = 1, getn(track.devices) do
                if (track:device(d).is_active) then
                    device_scan_total = device_scan_total + 1
                end
            end
        end

        for t = 1, getn(song.tracks) do
            set_main_buttons_active(false)

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

        set_main_buttons_active(true)
    end, debug.traceback)
    if (not ok) then
        print("OVERSAMPLE enumerate_tracks ERROR:\n" .. tostring(err))
    end
end

function enumerate_devices(track)
    local ok, err = xpcall(function()
        set_main_buttons_active(false)

        for d = 1, getn(track.devices) do
            if (dialog and not dialog.visible) then
                print('Dialog closed, stopping.')
                return
            end

            local device = track:device(d)

            if (device.is_active) then
                device_scan_count = device_scan_count + 1
                vb.views.status.text = string.format('Scanning devices... (%d/%d)', device_scan_count, device_scan_total)

                if (not devices[device.name]) then
                    -- print('Resetting device "' .. device.name .. '".')
                    devices[device.name] = {}
                end

                if (not devices[device.name]["instances"]) then
                    -- print('Resetting device instances for "' .. device.name .. '".')
                    devices[device.name]["instances"] = {}
                end

                table.insert(devices[device.name]["instances"], device)

                -- Invalidate the cache if this plugin's preset (and thus possibly
                -- its parameter list) changes while the song is open.
                pcall(function()
                  device.active_preset_observable:remove_notifier(on_device_preset_changed)
                  device.active_preset_observable:add_notifier(function()
                    on_device_preset_changed(device)
                  end)
                end)
            end

            coroutine.yield()
        end
    end, debug.traceback)
    if (not ok) then
        print("OVERSAMPLE enumerate_devices ERROR:\n" .. tostring(err))
    end
end

function get_parameters(device_name)
    local cached = cached_parameters[device_name]
    if (cached) then
        -- Reject a stale cache: empty, placeholder-only, or — most importantly —
        -- shorter than the plugin's current parameter count (a truncated list
        -- left behind by an interrupted scan, or by an under-reported #count on
        -- VST3 plugins). A full cache matches the live count exactly.
        local instances = ensure_device_instances(device_name)
        local device = instances[1]
        if (device and #cached == count_parameters(device)
            and #cached > 0 and type(cached[1]) == "string"
            and not cached[1]:match("^%(parameter %d+%)$")) then
            return cached
        end
        cached_parameters[device_name] = nil
    end

    local instances = ensure_device_instances(device_name)
    local device = instances[1]
    if (not device) then
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
    while (p <= 4096) do
        local ok, parameter = pcall(function()
            return device:parameter(p)
        end)
        if (not ok or not parameter) then
            break
        end

        local name = parameter.name
        if (name and name ~= "") then
            parameters[p] = name
            got_real = true
        else
            parameters[p] = ("(parameter %d)"):format(p)
        end

        p = p + 1
        -- Yield every few parameters so Renoise stays responsive during the
        -- (one-time) scan of plugins with very large parameter counts.
        if (p % 8 == 0) then
            coroutine.yield()
        end
    end

    -- Cache the result so we never iterate this plugin's parameters again
    -- (until the device type is removed/re-added or its preset changes). The
    -- cache is kept both per-song (tool_data) and machine-wide (preferences),
    -- so the installed plugin is only ever reached into once. Only cache a
    -- non-empty enumeration; a partial or empty pass is retried the next time
    -- it is needed.
    if (got_real) then
        cached_parameters[device_name] = parameters
        cache_dirty = true
        global_cache_dirty = true
    end

    return parameters
end

-- Count a plugin's exposed parameters by probing until device:parameter(p)
-- raises (the true end of the list). Used to validate cached lists, since the
-- length operator ('#') can under-report the count for some VST3 plugins.
-- Count the parameters a device actually exposes by probing device:parameter(p)
-- until it raises. Declared global (not local) because get_parameters,
-- apply_parameter_value and enumerate_parameters are defined before this point and
-- call it; a forward reference to a local would resolve to nil and crash.
function count_parameters(device)
    local n = 0
    local p = 1
    while (p <= 4096) do
        local ok = pcall(function()
            return device:parameter(p)
        end)
        if (not ok) then
            break
        end
        n = n + 1
        p = p + 1
    end
    return n
end

function enumerate_parameters(device_name)
    -- print('enumerate_parameters')
    if (dialog and dialog.visible and vb.views["set_values_button"]) then
        set_main_buttons_active(false)
    end

    local parameters = get_parameters(device_name)

    if (dialog and dialog.visible and vb.views["set_values_button"]) then
        set_main_buttons_active(true)
    end

    return parameters
end

-- Preview the minimum ("min") or maximum ("max") value of every relevant
-- parameter in the grid by moving the UI controls only. Nothing is written to the
-- plugin here; the separate "Set" button applies the resulting UI state to the
-- devices. This lets the user see the extreme before committing it.
function extreme_values(extreme)
    set_main_buttons_active(false)

    local verb = (extreme == "min") and "minimum" or "maximum"
    if (vb.views.status) then
        vb.views.status.text = 'Setting controls to ' .. verb .. '...'
    end

    -- Collect the rows that have a device so we can report progress and avoid
    -- re-scanning inside the sliced loop.
    local work = {}
    for row_number, selected_device in ipairs(selected_devices) do
        local device_name = selected_device["device_name"]
        if (device_name) then
            local device_instances = ensure_device_instances(device_name)
            if (#device_instances > 0) then
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
        local spopup = vb.views[ids["parameter_value_secondary_popup_id"]]
        local sec_choices = selected_devices[row_number]["secondary_parameter_choices"]
        if (not sec_choices) then
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
        selected_devices[row_number]["secondary_parameter_index"] = sec_index
        selected_devices[row_number]["secondary_parameter_name"] = sec_param.name
        selected_devices[row_number]["secondary_parameter_value"] = target_value
        selected_devices[row_number]["secondary_parameter_choices"] = sec_choices
    end

    -- Move the primary value control (and any revealed dependent secondary) for
    -- one row to the requested extreme, purely in the UI.
    local function display_extreme(row_number, device_name, device_instances)
        local parameter_index = selected_devices[row_number]["parameter_index"]
        if (not parameter_index) then
            return
        end
        local device = device_instances[1]
        local parameter = device:parameter(parameter_index)
        local target = (extreme == "min") and parameter.value_min or parameter.value_max
        apply_value_to_control(row_number, device_name, device_instances, parameter_index, target)

        -- The new primary value may reveal a dependent secondary (e.g. Pro-Q's
        -- "Processing Resolution"); if so, preview it at the same extreme.
        local sec_index = selected_devices[row_number]["secondary_parameter_index"]
        if (sec_index) then
            local sec_param = device:parameter(sec_index)
            local sec_target = (extreme == "min") and sec_param.value_min or sec_param.value_max
            apply_secondary_value_to_control(row_number, device_instances, sec_index, sec_target)
        end
    end

    -- Run the UI update in a sliced coroutine so the dialog stays responsive.
    local function process()
        if (dialog and not dialog.visible) then
            return
        end
        for _, w in ipairs(work) do
            local ok, err = pcall(display_extreme, w[1], w[2], w[3])
            if (not ok) then
                print("OVERSAMPLE extreme_values UI error row " .. tostring(w[1]) .. ": " .. tostring(err))
            end
            processed = processed + 1
            if (vb.views.status) then
                if (total > 0) then
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
        if (vb.views.status) then
            vb.views.status.text = 'Controls set to ' .. verb .. '.'
        end
        set_main_buttons_active(true)
    end

    local slicer = ProcessSlicer(process, done)
    slicer:start()
end

-- Enable/disable the three action buttons (Set, Minimize, Maximize) together,
-- mirroring the "Set" button's active state used while scans are in flight.
-- Declared global (not local) because it is invoked from several top-level
-- functions (enumerate_tracks, enumerate_devices, add_device_items, render_settings_rows…)
-- that are defined before this point; a forward reference to a local would resolve
-- to the global environment (nil) and crash the scan.
function set_main_buttons_active(active)
    if (not vb or not vb.views) then
        return
    end
    for _, id in ipairs({ "set_values_button", "minimize_values_button", "maximize_values_button" }) do
        local view = vb.views[id]
        if (view) then
            pcall(function()
                view.active = active
            end)
        end
    end

    -- Disable every control in the grid while an action (Set/Minimize/Maximize) or a
    -- background scan is in flight, so the user can't edit rows mid-operation.
    for r = 1, settings_row_count do
        local ids = create_settings_row_identifiers(r)
        for _, key in ipairs({
            "device_popup_id",
            "parameter_popup_id",
            "parameter_value_popup_id",
            "parameter_value_slider_id",
            "parameter_value_secondary_popup_id",
            "add_button_id"
        }) do
            local view = vb.views[ids[key]]
            if (view) then
                pcall(function()
                    view.active = active
                end)
            end
        end
    end
end

function set_values()
    set_main_buttons_active(false)
    local parameters_changed = 0

    for row_number, selected_device in ipairs(selected_devices) do
        local device_name = selected_device["device_name"]
        local parameter_name = selected_device["parameter_name"]
        local parameter_value = selected_device["parameter_value"]
        local device_instances = ensure_device_instances(device_name)

        if (parameter_value == nil) then
            parameter_value = 0
        end

        for i, device in ipairs(device_instances) do
            local count = count_parameters(device)
            local parameter_index = selected_device["parameter_index"]

            -- Resolve by name when known: robust to index drift and to the
            -- "known parameter shown first" fast path, where the index is only
            -- valid within the short known-only list.
            if (parameter_name) then
                for p = 1, count_parameters(device) do
                    if (device:parameter(p).name == parameter_name) then
                        parameter_index = p
                        break
                    end
                end
            end

            if (parameter_index and parameter_index >= 1 and parameter_index <= count) then
                local parameter = device:parameter(parameter_index)
                parameter:record_value(parameter_value)
                parameters_changed = parameters_changed + 1
            end

            -- Apply the dependent secondary parameter (e.g. Pro-Q's
            -- "Processing Resolution"), resolved by name for robustness.
            local sec_index = selected_device["secondary_parameter_index"]
            local sec_value = selected_device["secondary_parameter_value"]
            local sec_name = selected_device["secondary_parameter_name"]
            if (sec_index and sec_value ~= nil) then
                local sidx = sec_index
                if (sec_name) then
                    for p = 1, count_parameters(device) do
                        if (device:parameter(p).name == sec_name) then
                            sidx = p
                            break
                        end
                    end
                end
                if (sidx and sidx >= 1 and sidx <= count) then
                    device:parameter(sidx):record_value(sec_value)
                    parameters_changed = parameters_changed + 1
                end
            end
        end
    end

    local verb = nil
    local button_text = nil

    vb.views.status.text = parameters_changed .. ' parameter values set.'
    set_main_buttons_active(true)
end
