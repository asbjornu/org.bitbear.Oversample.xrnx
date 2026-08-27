-- Lua 5.2+ removed table.getn; provide a compatibility shim.
if not table.getn then
  table.getn = function(t) return #t end
end

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
local device_popups = {}
local selected_devices = {}
local known_devices_parameters = {
     ['VST: FabFilter: Saturn'] = 'High Quality',
     ['VST: FabFilter: Saturn 2'] = 'High Quality Mode',
     ['VST: FabFilter: Pro-MB'] = 'Oversampling',
     ['VST: FabFilter: Pro-C 2'] = 'Oversampling',
     ['VST: FabFilter: Pro-L 2'] = 'Oversampling',
     ['VST: FabFilter: Pro-Q 2'] = {
        'Processing Mode', 'Processing Resolution'
     },
      ['VST: FabFilter: Pro-Q 3'] = {
         'Processing Mode', 'Processing Resolution'
      },
      ['VST3: FabFilter: Saturn'] = 'High Quality',
      ['VST3: FabFilter: Saturn 2'] = 'High Quality Mode',
      ['VST3: FabFilter: Pro-MB'] = 'Oversampling',
      ['VST3: FabFilter: Pro-C 2'] = 'Oversampling',
      ['VST3: FabFilter: Pro-L 2'] = 'Oversampling',
      ['VST3: FabFilter: Pro-Q 2'] = {
         'Processing Mode', 'Processing Resolution'
      },
      ['VST3: FabFilter: Pro-Q 3'] = {
         'Processing Mode', 'Processing Resolution'
      },
}

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
local function encode_field(str)
  return string.len(str) .. ";" .. str
end

local function decode_fields(str)
  local fields = {}
  local i = 1
  local len = string.len(str)
  while (i <= len) do
    local sep = string.find(str, ";", i, true)
    if (not sep) then
      break
    end
    local field_len = tonumber(string.sub(str, i, sep - 1)) or 0
    table.insert(fields, string.sub(str, sep + 1, sep + field_len))
    i = sep + 1 + field_len
  end
  return fields
end

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

  -- Per-song (travels with the .xrns file; overrides machine-wide).
  local data = renoise.song().tool_data
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

  for t = 1, table.getn(song.tracks) do
    local track = song:track(t)
    for d = 1, table.getn(track.devices) do
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
  for t = 1, table.getn(song.tracks) do
    local track = song:track(t)
    for d = 1, table.getn(track.devices) do
      local device = track:device(d)
      if (device.is_active and not seen[device.name]) then
        seen[device.name] = true
        names[#names + 1] = device.name
      end
    end
  end
  return names
end

local function same_name_set(a, b)
  if (#a ~= #b) then return false end
  local seen = {}
  for _, v in ipairs(a) do seen[v] = true end
  for _, v in ipairs(b) do
    if (not seen[v]) then return false end
  end
  return true
end

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
  for t = 1, table.getn(song.tracks) do
    local track = song:track(t)
    for d = 1, table.getn(track.devices) do
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
local function on_device_preset_changed(device)
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

  for t = 1, table.getn(song.tracks) do
    attach_track(song:track(t))
  end

  song.tracks_observable:add_notifier(function()
    for t = 1, table.getn(song.tracks) do
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
  device_popups = {}
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
  attach_song_device_notifiers()

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
                vb:button {
                    id = "set_values_button",
                    text = "Set",
                    width = HALF_COLUMN_WIDTH,
                    active = false,
                    notifier = set_values
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
        vb.views.status.text = 'Done.'
        return
    end

    -- Names unavailable or out of date: run the one-time scan to collect live
    -- instances and reconcile against the persisted list.
    vb.views.status.text = 'Finding devices...'

    devices = {}
    device_popups = {}
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
        vb.views[ids["parameter_value_slider_id"]] = nil
        vb.views[ids["settings_row_id"]] = nil
        vb.views[ids["add_button_id"]] = nil
    end

    vb.views["set_values_button"] = nil
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
    local parameter_value_slider_id = settings_row_identifiers["parameter_value_slider_id"]
    local settings_row_id = settings_row_identifiers["settings_row_id"]
    local add_button_id = settings_row_identifiers["add_button_id"]

    device_popups[row_number] = device_popup_id

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
        vb:slider {
            id = parameter_value_slider_id,
            width = HALF_COLUMN_WIDTH,
            active = false,
            notifier = function(value)
                print(value)
                local parameter_value = vb.views[parameter_value_slider_id].value
                local parameter_popup = vb.views[parameter_popup_id]
                local parameter_name = parameter_popup.items[value]
                local selected_parameter_index = parameter_popup.value
                local device_popup = vb.views[device_popup_id]
                local selected_device_index = device_popup.value
                local device_name = device_popup.items[selected_device_index]
                parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
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

function create_settings_row_identifiers(row_number)
    if (not row_number) then
        row_number = settings_row_count
    end

    return {
        ["device_popup_id"] = "devices_popup_" .. row_number,
        ["parameter_popup_id"] = "parameters_popup_" .. row_number,
        ["parameter_value_slider_id"] = "parameter_value_slider_" .. row_number,
        ["settings_row_id"] = "settings_row_" .. row_number,
        ["add_button_id"] = "add_button_" .. row_number
    }
end

local function render_settings_rows(device_names)
    local container = vb.views.settings_container
    settings_row_count = 0
    device_popups = {}

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

    vb.views["set_values_button"].active = true
end

function add_device_items_init()
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

    cached_device_names = device_items
    save_global_device_name_cache()

    render_settings_rows(device_items)

    vb.views.status.text = 'Done.'
end

function add_device_items(device_popup_id, selected_device_index)
    local device_items = {}
    vb.views["set_values_button"].active = false

    if (next(devices) ~= nil) then
        for k, _ in pairs(devices) do
            device_items[#device_items + 1] = k
        end
    else
        for _, n in ipairs(cached_device_names) do
            device_items[#device_items + 1] = n
        end
    end

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

    vb.views["set_values_button"].active = true
    vb.views.status.text = 'Done.'
end

-- Set the value slider's range/current value from a resolved parameter index.
local function set_slider(row_number, device_instances, parameter_index)
    local device = device_instances[1]
    local parameter = device:parameter(parameter_index)
    local settings_row_identifiers = create_settings_row_identifiers(row_number)
    local slider = vb.views[settings_row_identifiers["parameter_value_slider_id"]]

    slider.min = parameter.value_min
    slider.max = parameter.value_max
    slider.value = parameter.value
    slider.active = true
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

    local parameter_index = nil
    for p = 1, table.getn(device.parameters) do
        if (device:parameter(p).name == parameter_name) then
            parameter_index = p
            break
        end
    end
    if (not parameter_index) then
        return
    end

    selected_devices[row_number]["parameter_name"] = parameter_name
    selected_devices[row_number]["parameter_index"] = parameter_index
    set_slider(row_number, device_instances, parameter_index)
end

function device_selected(device_index, device_name, parameter_popup_id, row_number)
    vb.views["set_values_button"].active = false
    selected_devices[row_number] = {
         ["device_name"] = device_name,
         ["device_index"] = device_index
    }
    -- print('device_selected')

    local known_parameters = known_devices_parameters[device_name]
    local parameters_popup = vb.views[parameter_popup_id]

    -- Populate the parameter dropdown from the (already known) full list, then
    -- snap to the recognised "Oversample" parameter. No waiting required.
    local function apply_parameters(parameters)
        if (not parameters) then
            parameters = {}
        end

        parameters_popup.items = parameters
        parameters_popup.active = true

        if (known_parameters) then
            local target = (type(known_parameters) == "string") and known_parameters or known_parameters[1]
            for i, p in ipairs(parameters) do
                if (p == target) then
                    parameters_popup.value = i
                    break
                end
            end
        end

        vb.views.status.text = 'Done.'
        vb.views["set_values_button"].active = true
    end

    if (cached_parameters[device_name]) then
        -- Already cached (this session, song, or a previous run): no scan.
        apply_parameters(cached_parameters[device_name])
        if (known_parameters) then
            local known_name = (type(known_parameters) == "string") and known_parameters or known_parameters[1]
            apply_parameter_value(row_number, device_name, known_name)
        end
        return
    end

    -- Not cached yet: show the recognised parameter(s) immediately so the user
    -- can act at once, then run the one-time scan to back-fill the rest.
    if (known_parameters) then
        local items = (type(known_parameters) == "string") and { known_parameters } or { table.unpack(known_parameters) }
        local known_name = (type(known_parameters) == "string") and known_parameters or known_parameters[1]
        parameters_popup.items = items
        parameters_popup.value = 1
        parameters_popup.active = true
        -- Reflect the known parameter's current value on the slider right away,
        -- without waiting for the full parameter scan to complete.
        apply_parameter_value(row_number, device_name, known_name)
        vb.views.status.text = 'Ready.'
        vb.views["set_values_button"].active = true
    else
        vb.views.status.text = 'Finding parameters...'
    end

    local slicer = ProcessSlicer(enumerate_parameters, function(return_value)
        apply_parameters(return_value[1])
    end, device_name)

    -- print('enumerate_devices:ProcessSlicer:start')
    slicer:start()
end

-- Set the value slider's range/current value from a resolved parameter index.
function parameter_selected(parameter_index, parameter_name, device_name, row_number)
    print('parameter_selected:' .. device_name)
    local device_instances = ensure_device_instances(device_name)
    selected_devices[row_number]["parameter_name"] = parameter_name
    selected_devices[row_number]["parameter_index"] = parameter_index

    for k, v in ipairs(device_instances) do
        vb.views["set_values_button"].active = false
        set_slider(row_number, device_instances, parameter_index)
    end

    local device = device_instances[1]
    if (device) then
        local parameter = device:parameter(parameter_index)
        print(("        %s[%d]: %d, min(%d), $max(%d), quantum(%d), default(%d), string(%s)."):format(
            parameter.name,
            parameter_index,
            parameter.value,
            parameter.value_min,
            parameter.value_max,
            parameter.value_quantum,
            parameter.value_default,
            parameter.value_string
        ))
    end

    vb.views["set_values_button"].active = true
end

function parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
    selected_devices[row_number]["parameter_value"] = parameter_value
end

function enumerate_tracks()
    -- print('enumerate_tracks')
    local song = renoise.song()

    for t = 1, table.getn(song.tracks) do
        vb.views["set_values_button"].active = false

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

    vb.views["set_values_button"].active = true
end

function enumerate_devices(track)
    vb.views["set_values_button"].active = false

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
end

function get_parameters(device_name)
    if (cached_parameters[device_name]) then
        print('Returning cached parameters for "' .. device_name .. '".')
        return cached_parameters[device_name]
    end

    local instances = ensure_device_instances(device_name)
    local device = instances[1]
    if (not device) then
        -- Cannot reach into the plugin (e.g. scanned concurrently): bail out.
        return {}
    end

    local parameters = {}

    for p = 1, table.getn(device.parameters) do
        if (dialog and not dialog.visible) then
            print('Dialog closed, stopping.')
            return parameters
        end

        local parameter = device:parameter(p)

        vb.views.status.text = device.name .. ': ' .. parameter.name

        parameters[p] = parameter.name

        coroutine.yield()
    end

    -- Cache the result so we never iterate this plugin's parameters again
    -- (until the device type is removed/re-added or its preset changes).
    -- The cache is kept both per-song (tool_data) and machine-wide
    -- (preferences), so the installed plugin is only ever reached into once.
    cached_parameters[device_name] = parameters
    cache_dirty = true
    global_cache_dirty = true

    return parameters
end

function enumerate_parameters(device_name)
    -- print('enumerate_parameters')
    vb.views["set_values_button"].active = false

    local parameters = get_parameters(device_name)

    vb.views["set_values_button"].active = true

    return parameters
end

function set_values()
    local set_values_button = vb.views["set_values_button"]
    set_values_button.active = false
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
            local parameter_index = selected_device["parameter_index"]

            -- Resolve by name when known: robust to index drift and to the
            -- "known parameter shown first" fast path, where the index is only
            -- valid within the short known-only list.
            if (parameter_name) then
                for p = 1, table.getn(device.parameters) do
                    if (device:parameter(p).name == parameter_name) then
                        parameter_index = p
                        break
                    end
                end
            end

            local parameter = device:parameter(parameter_index)

            parameter:record_value(parameter_value)
            parameters_changed = parameters_changed + 1
        end
    end

    local verb = nil
    local button_text = nil

    vb.views.status.text = parameters_changed .. ' parameter values set.'
    set_values_button.active = true
end
