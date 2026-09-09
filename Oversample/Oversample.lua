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

-- Renoise's ViewBuilder has no "fixed column layout" mode and exposes no text
-- metrics. To keep the Parameter/Value/Secondary columns aligned across every row
-- we give each control in a column the same fixed width. Those widths are derived
-- from the widest *known* label (estimated from its character length) so the
-- columns hug their content instead of being arbitrarily wide.
local function estimate_text_width(str)
    return math.ceil(string.len(tostring(str)) * CONTENT_HEIGHT * 0.4) + 16
end

local function max_text_width(strings)
    local w = 0
    for _, s in ipairs(strings) do
        local e = estimate_text_width(s)
        if (e > w) then
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
        local e = math.ceil(string.len(tostring(s)) * CONTENT_HEIGHT * 0.3) + 8
        if (e > w) then
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
    if (type(v) == "string") then
        _param_names[#_param_names + 1] = v
    elseif (type(v) == "table") then
        if (v.primary) then _param_names[#_param_names + 1] = v.primary end
        if (v[1]) then _param_names[#_param_names + 1] = v[1] end
        local sn = nil
        if (type(v.secondary) == "table" and v.secondary.name) then
            sn = v.secondary.name
        elseif (type(v.secondary) == "string") then
            sn = v.secondary
        elseif (type(v[2]) == "string") then
            sn = v[2]
        elseif (type(v[2]) == "table" and v[2].name) then
            sn = v[2].name
        end
        if (sn) then
            _secondary_labels[#_secondary_labels + 1] = sn .. ":"
        end
    end
end

for norm, entries in pairs(core.known_osig) do
    local axes = core.known_osig_axes and core.known_osig_axes[norm]
    if (axes) then
        for _, l in ipairs(axes[1].labels) do
            _value_labels[#_value_labels + 1] = l
        end
    else
        for _, e in ipairs(entries) do
            if (e.values) then
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

-- In-memory oversampling state-chunk signatures, keyed by device name (plugin
-- type). Each value is an entries array (see oversample_core.diff_blobs_multi): a
-- list of { pos, values = { [label] = byte } }. Populated by the calibration dialog
-- and used as a fallback when a plugin does not expose its oversampling as a host
-- parameter (e.g. FabFilter VST3).
local osig = {}

-- Combined per-song cache document, stored in renoise.song().tool_data (the
-- portable copy that travels with the .xrns file).
local tool_cache_doc = renoise.Document.create("OversampleCache") {
  parameters = renoise.Document.ObservableStringList(),
  device_names = renoise.Document.ObservableStringList(),
  osig = renoise.Document.ObservableStringList()
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

-- Coerce a renoise.Document list element to a plain string. Document Node
-- elements (userdata) can appear when stale/corrupt cached data is parsed, in
-- which case we extract the node's text value (or skip it if unrecoverable).
local function list_item_str(item)
  if (type(item) == "string") then
    return item
  end
  if (type(item) == "userdata") then
    local ok, v = pcall(function() return item.value end)
    if (ok and type(v) == "string") then return v end
    local ok2, v2 = pcall(function() return item.text_value end)
    if (ok2 and type(v2) == "string") then return v2 end
  end
  return nil
end

-- Merge one serialized cache list (a renoise.Document string list) into the
-- in-memory parameter mirror. Per-song entries override machine-wide ones.
local function merge_cache_list(list)
  for i = 1, list_count(list) do
    local item = list_item_str(list[i])
    if (item) then
      local fields = decode_fields(item)
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

-- Merge a serialized oversampling-signature list into the in-memory mirror. Each
-- stored item encodes the device name followed by the encoded entries.
local function merge_osig_list(list)
  for i = 1, list_count(list) do
    local item = list_item_str(list[i])
    if (item) then
      local fields = decode_fields(item)
      if (#fields >= 2) then
        -- Cache entries may have been persisted under a raw, host-prefixed name
        -- (e.g. "VST3: FabFilter: ..."); normalize so lookups via
        -- osig[core.normalize_device_name(...)] can still find them.
        local name = core.normalize_device_name(fields[1])
        local entries = core.decode_osig(fields[2])
        if (name and #entries > 0) then
          osig[name] = entries
        end
      end
    end
  end
end

-- Fill a renoise.Document string list with the current in-memory signatures.
local function fill_osig_list(list)
  while (list_count(list) > 0) do list:remove(1) end
  for name, entries in pairs(osig) do
    list:insert(encode_field(name) .. encode_field(core.encode_osig(entries)))
  end
end

-- Load both caches from the machine-wide preferences and the per-song tool_data.
function load_tool_cache()
  cached_parameters = {}
  cached_device_names = {}
  -- Rebuild the in-memory signature map from scratch so a signature learned from a
  -- previous song cannot leak into the next one (which would make Set patch unrelated
  -- bytes on a VST3 device). The machine-wide, per-song, and built-in entries are
  -- re-merged below in that order.
  for k in pairs(osig) do osig[k] = nil end
  -- Drop any per-song signature list carried over in the reused document object; it is
  -- repopulated by from_string() when the current song has tool_data, and stays empty
  -- otherwise (so stale entries are never merged).
  while (list_count(tool_cache_doc.osig) > 0) do tool_cache_doc.osig:remove(1) end

  -- Machine-wide (survives across songs and sessions).
  merge_cache_list(renoise.tool().preferences.cached_parameters)
  merge_name_list(renoise.tool().preferences.cached_device_names)
  merge_osig_list(renoise.tool().preferences.osig)

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
        while (list_count(tool_cache_doc.osig) > 0) do
          tool_cache_doc.osig:remove(1)
        end
      end
    end
    pcall(function()
      merge_cache_list(tool_cache_doc.parameters)
      merge_name_list(tool_cache_doc.device_names)
      merge_osig_list(tool_cache_doc.osig)
    end)
  end

  -- Built-in signatures (learned offline from saved songs) are authoritative: they
  -- always override any stale cached signature (e.g. left over from the removed
  -- calibration flow) so a cached entry can never shadow a verified one.
  for name, entries in pairs(core.known_osig or {}) do
    osig[name] = entries
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

  fill_osig_list(tool_cache_doc.osig)

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
  save_global_osig()
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

-- Write the in-memory oversampling signatures into the machine-wide preferences.
function save_global_osig()
  fill_osig_list(renoise.tool().preferences.osig)
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

-- Find another device in the song that is the same plugin (matched by normalised
-- name) but a different build, and which exposes the given parameter. This is how
-- we obtain dropdown labels for a VST3 device whose oversampling parameter is not
-- host-exposed: we borrow them from the VST2 build of the same plugin. The VST2
-- build is preferred but any exposing sibling is accepted. Returns the device, or
-- nil when none qualifies.
local function find_sibling_device(device_name, parameter_name)
  local norm = core.normalize_device_name(device_name)
  local song = renoise.song()
  local fallback = nil
  for t = 1, getn(song.tracks) do
    local track = song:track(t)
    for d = 1, getn(track.devices) do
      local dev = track:device(d)
      if (dev.is_active and core.normalize_device_name(dev.name) == norm
          and dev.name ~= device_name) then
        local count = count_parameters(dev)
        local names = {}
        for p = 1, count do
          names[p] = dev:parameter(p).name
        end
        if (match_parameter(names, parameter_name)) then
          if (dev.name:sub(1, 4) == "VST:") then
            return dev
          end
          fallback = fallback or dev
        end
      end
    end
  end
  return fallback
end

-- The separator used to combine a primary + dependent secondary label into a
-- single osig target key (e.g. "Linear Phase / Maximum").
local SECONDARY_SEP = " / "

-- Compute the combined osig target label for a row (primary, plus secondary when
-- one is active). Returns nil for non-osig-driven rows.
local function osig_target_for_row(row_number)
  local sd = selected_devices[row_number]
  if (not sd or not sd["osig_driven"]) then
    return nil
  end
  local primary = sd["osig_target_label"]
  local sec = sd["osig_target_label_sec"]
  if (sec) then
    if (not primary) then
      return sec
    end
    -- A primary can itself be a combined label (e.g. Pro-Q 3's "Linear Phase / Medium");
    -- the dependent secondary replaces the trailing portion (the axis-1 value before the
    -- first " / "), so we never append a third segment that matches no signature label
    -- (e.g. "Linear Phase / Medium / High").
    local sep = primary:find(SECONDARY_SEP, 1, true)
    if (sep) then
      return primary:sub(1, sep - 1) .. SECONDARY_SEP .. sec
    end
    return primary .. SECONDARY_SEP .. sec
  end
  return primary
end

local on_song_devices_changed = function()
  prune_parameter_cache()
  devices_valid = false
  cached_device_names = collect_device_names()
  device_names_dirty = true
  global_device_names_dirty = true
  save_global_device_name_cache()
  refresh_device_popups()
  add_rows_for_new_known_devices()
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
    on_song_devices_changed()
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
        vb.views[ids["parameter_label_id"]] = nil
        vb.views[ids["parameter_value_popup_id"]] = nil
        vb.views[ids["parameter_value_slider_id"]] = nil
        vb.views[ids["parameter_value_secondary_popup_id"]] = nil
        vb.views[ids["parameter_value_secondary_label_id"]] = nil
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
    local parameter_label_id = settings_row_identifiers["parameter_label_id"]
    local parameter_value_popup_id = settings_row_identifiers["parameter_value_popup_id"]
    local parameter_value_slider_id = settings_row_identifiers["parameter_value_slider_id"]
    local parameter_value_secondary_popup_id = settings_row_identifiers["parameter_value_secondary_popup_id"]
    local parameter_value_secondary_label_id = settings_row_identifiers["parameter_value_secondary_label_id"]
    local settings_row_id = settings_row_identifiers["settings_row_id"]
    local add_button_id = settings_row_identifiers["add_button_id"]

    return vb:row {
        id = settings_row_id,
        spacing = DEFAULT_CONTROL_SPACING,
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
            width = PARAMETER_WIDTH,
            active = false,
            notifier = function(value)
                local parameter_name = vb.views[parameter_popup_id].items[value]
                local device_popup = vb.views[device_popup_id]
                local selected_device_index = device_popup.value
                local device_name = device_popup.items[selected_device_index]
                parameter_selected(value, parameter_name, device_name, row_number)
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
                if (not selected_devices[row_number]) then
                    return
                end
                local ids = create_settings_row_identifiers(row_number)
                local popup = vb.views[ids["parameter_value_popup_id"]]
                local device_popup = vb.views[device_popup_id]
                local device_name = device_popup.items[device_popup.value]
                local device_instances = ensure_device_instances(device_name)
                if (not device_instances[1]) then
                    return
                end
                local choices = selected_devices[row_number]["parameter_choices"]
                if (selected_devices[row_number]["osig_driven"]) then
                    -- VST3 row: record the chosen label (the value is applied via
                    -- the state-chunk signature, not a host parameter).
                    if (choices and choices[value]) then
                        local lbl = choices[value].label
                        if (selected_devices[row_number]["osig_multi_axis"]) then
                            -- Rebuild the combined key from the (changed) primary axis and
                            -- the current secondary axis selection.
                            local axes = selected_devices[row_number]["osig_axes"]
                            local a2 = selected_devices[row_number]["osig_axis2_label"]
                            if (a2 == nil and axes and axes[2]) then
                                a2 = axes[2].labels[1]
                            end
                            if (a2 and a2 ~= "") then
                                selected_devices[row_number]["osig_target_label"] = lbl .. SECONDARY_SEP .. a2
                            else
                                selected_devices[row_number]["osig_target_label"] = lbl
                            end
                        else
                            selected_devices[row_number]["osig_target_label"] = lbl
                            selected_devices[row_number]["osig_target_label_sec"] = nil
                        end
                    end
                else
                    local v
                    if (choices and choices[value]) then
                        v = choices[value].value
                    end
                    if (v ~= nil) then
                        selected_devices[row_number]["parameter_value"] = v
                    end
                end
                update_secondary(row_number, device_name, device_instances)
            end,
        },
        vb:slider {
            id = parameter_value_slider_id,
            width = VALUE_WIDTH,
            active = false,
            notifier = function(value)
                local parameter_value = value
                local parameter_name = selected_devices[row_number]["parameter_name"]
                local device_popup = vb.views[device_popup_id]
                local device_name = device_popup.items[device_popup.value]
                parameter_value_changed(parameter_value, parameter_name, device_name, row_number)
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
                    if (not selected_devices[row_number]) then
                        return
                    end
                    local ids = create_settings_row_identifiers(row_number)
                    local spopup = vb.views[ids["parameter_value_secondary_popup_id"]]
                    local device_popup = vb.views[device_popup_id]
                    local device_name = device_popup.items[device_popup.value]
                    local device_instances = ensure_device_instances(device_name)
                    if (not device_instances[1]) then
                        return
                    end
                    local sec_index = selected_devices[row_number]["secondary_parameter_index"]
                    if (selected_devices[row_number]["osig_driven"]) then
                        if (selected_devices[row_number]["osig_multi_axis"]) then
                            -- Independent axis: the secondary popup holds this device's own
                            -- axis-2 labels; rebuild the combined key from the current
                            -- primary axis value and the newly chosen axis-2 label.
                            local axes = selected_devices[row_number]["osig_axes"]
                            local sec_labels = axes and axes[2] and axes[2].labels
                            if (sec_labels and sec_labels[value]) then
                                local a2 = sec_labels[value]
                                local a1 = selected_devices[row_number]["osig_target_label"]
                                local a1part = a1
                                if (type(a1) == "string") then
                                    local sep = a1:find(SECONDARY_SEP, 1, true)
                                    if (sep) then
                                        a1part = a1:sub(1, sep - 1)
                                    end
                                end
                                selected_devices[row_number]["osig_axis2_label"] = a2
                                selected_devices[row_number]["osig_target_label"] = a1part .. SECONDARY_SEP .. a2
                            end
                        else
                            -- VST3 row: record the chosen secondary label for the combined
                            -- osig target key.
                            local choices = selected_devices[row_number]["secondary_parameter_choices"]
                            if (choices and choices[value]) then
                                selected_devices[row_number]["osig_target_label_sec"] = choices[value].label
                            end
                        end
                    elseif (sec_index) then
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
        },
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

    -- Only known devices have a meaningful oversampling parameter to drive, so
    -- only they get a row automatically. Each row's device dropdown still lists
    -- every device in the song, so any row can be reassigned by hand. The format
    -- prefix (VST/VST3/AU) is normalized away so one entry matches every format.
    local known_names = {}
    for _, n in ipairs(device_names) do
        if (known_devices_parameters[core.normalize_device_name(n)]) then
            known_names[#known_names + 1] = n
        end
    end

    for _, device_name in ipairs(known_names) do
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

    -- Offer the full, current device list so any row can target any device in
    -- the song. `cached_device_names` is kept in sync with the live song by the
    -- device-change handlers, whereas the `devices` map can be stale after a
    -- device is added or removed.
    for _, n in ipairs(cached_device_names) do
        device_items[#device_items + 1] = n
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

-- Refresh every device dropdown in the currently rendered settings rows so that
-- newly added (or removed) devices become (un)selectable. The currently chosen
-- device is preserved when it still exists in the song.
function refresh_device_popups()
    local names = {}
    for _, n in ipairs(cached_device_names) do
        names[#names + 1] = n
    end
    table.sort(names)

    for i = 1, settings_row_count do
        local ids = create_settings_row_identifiers(i)
        local device_popup_id = ids["device_popup_id"]
        local popup = vb.views[device_popup_id]
        if (popup) then
            local selected_name = popup.items[popup.value]
            popup.items = names
            local new_index = 1
            if (selected_name) then
                for j, n in ipairs(names) do
                    if (n == selected_name) then
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
    for i = 1, settings_row_count do
        local ids = create_settings_row_identifiers(i)
        local popup = vb.views[ids["device_popup_id"]]
        if (popup and popup.items and popup.value and popup.items[popup.value]) then
            set[popup.items[popup.value]] = true
        end
    end
    return set
end

-- Append a new settings row already pointing at the given device and populate its
-- parameter controls, exactly as if the user had added a row and picked it.
local function add_row_for_device(device_name)
    local settings_row = create_settings_row()
    vb.views.settings_container:add_child(settings_row)
    local ids = create_settings_row_identifiers()
    local device_popup_id = ids["device_popup_id"]
    local parameter_popup_id = ids["parameter_popup_id"]

    add_device_items(device_popup_id)

    local popup = vb.views[device_popup_id]
    if (popup) then
        for i, n in ipairs(popup.items) do
            if (n == device_name) then
                popup.value = i
                device_selected(i, device_name, parameter_popup_id, settings_row_count)
                break
            end
        end
    end
end

-- When a known device appears in the song, add a row for it automatically so the
-- user does not have to do it by hand. Devices already represented by a row are
-- skipped to avoid duplicates.
function add_rows_for_new_known_devices()
    if (not dialog or not dialog.visible) then
        return
    end

    local rendered = rendered_device_name_set()
    for _, name in ipairs(cached_device_names) do
        if (known_devices_parameters[core.normalize_device_name(name)] and not rendered[name]) then
            add_row_for_device(name)
        end
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
        if (span <= 0) then
            span = 1
        end
        for k = 0, steps do
            local v = lo + span * (k / steps)
            local ok, s, tv = pcall(function()
                parameter.value = v
                return parameter.value_string, parameter.value
            end)
            if (ok and type(s) == "string" and type(tv) == "number") then
                local key = string.format("%.12f", tv)
                if (not seen[key]) then
                    seen[key] = true
                    local label = s:match("^%s*(.-)%s*$")
                    if (label == "") then
                        label = s
                    end
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
    if (q and q > 0) then
        local n = math.floor((max_v - min_v) / q + 0.5)
        if (n < 2) then
            n = 2
        end
        if (n > 256) then
            n = 256
        end
        choices = probe_range(min_v, max_v, n)
        -- A misleading quantum (common with VST3) can collapse the probe onto a
        -- single step. When that happens, fall back to a full-range scan which
        -- still collapses correctly for a real enum but spreads out for a
        -- continuous parameter.
        if (#choices < 2) then
            choices = probe_range(min_v, max_v, 128)
        end
    else
        choices = probe_range(min_v, max_v, 128)
    end

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
local function update_secondary_osig(row_number, device_name, device_instances)
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids["parameter_value_secondary_popup_id"]]
    local sec_label = vb.views[ids["parameter_value_secondary_label_id"]]
    local sec_name = known_secondary(device_name)
    local primary_name = known_primary(device_name)

    local function hide_secondary()
        -- The enclosing row reserves the space while these controls are hidden.
        sec_popup.items = {""}
        sec_popup.value = 1
        sec_popup.active = false
        sec_popup.visible = false
        if (sec_label) then
            sec_label.text = ""
            sec_label.visible = false
        end
        selected_devices[row_number]["secondary_parameter_index"] = nil
        selected_devices[row_number]["secondary_parameter_value"] = nil
        selected_devices[row_number]["secondary_parameter_name"] = nil
        selected_devices[row_number]["osig_target_label_sec"] = nil
    end

    -- Multiple independent oversampling axes (e.g. Saturn 2's "High Quality" mode and
    -- "Linear Phase" toggle): the secondary popup shows the next axis' labels directly
    -- from the signature metadata, with no sibling host parameter involved.
    if (selected_devices[row_number] and selected_devices[row_number]["osig_multi_axis"]) then
        local axes = selected_devices[row_number]["osig_axes"]
        if (axes and axes[2]) then
            local sec_labels = axes[2].labels
            local a2 = selected_devices[row_number]["osig_axis2_label"]
            local sidx = 1
            for i, l in ipairs(sec_labels) do
                if (l == a2) then
                    sidx = i
                    break
                end
            end
            sec_popup.items = sec_labels
            sec_popup.value = sidx
            sec_popup.active = true
            sec_popup.visible = true
            if (sec_label) then
                sec_label.text = axes[2].name .. ":"
                sec_label.visible = true
            end

            -- Multi-axis devices have no dependent (sibling) secondary; clear any stale
            -- state left by a previously-selected device so osig_target_for_row() never
            -- appends a leftover secondary label (e.g. "Off / On / Medium").
            selected_devices[row_number]["secondary_parameter_choices"] = nil
            selected_devices[row_number]["secondary_parameter_index"] = nil
            selected_devices[row_number]["secondary_parameter_value"] = nil
            selected_devices[row_number]["secondary_parameter_name"] = nil
            selected_devices[row_number]["osig_target_label_sec"] = nil
            return
        end
    end

    if (not sec_name or not primary_name) then
        hide_secondary()
        return
    end
    if (selected_devices[row_number]["parameter_name"] ~= primary_name) then
        hide_secondary()
        return
    end

    -- The VST3 device does not expose the parameter, so the secondary labels come
    -- from the sibling device's parameter.
    local sibling = selected_devices[row_number]["sibling_device"]
    if (not sibling) then
        hide_secondary()
        return
    end

    local primary_label = selected_devices[row_number]["osig_target_label"]
    -- osig labels can combine multiple axes (e.g. Pro-Q 3's "Linear Phase / Medium");
    -- only the portion before the " / " separator is the primary-axis value we compare
    -- against SECONDARY_SHOW_WHEN, so the dependent secondary still appears for those modes.
    local primary_axis = primary_label
    if (primary_axis) then
        local sep = primary_axis:find(SECONDARY_SEP, 1, true)
        if (sep) then primary_axis = primary_axis:sub(1, sep - 1) end
    end
    -- The combined label's trailing portion is the dependent-secondary value it already
    -- implies (e.g. the "Maximum" in "Linear Phase / Maximum"), used to seed the secondary
    -- so Minimize/Maximize land on the correct resolution rather than the first choice.
    local primary_suffix
    if (primary_label) then
        local sep = primary_label:find(SECONDARY_SEP, 1, true)
        if (sep) then primary_suffix = primary_label:sub(sep + 3) end
    end
    if (not primary_label or not loose_eq(primary_axis, SECONDARY_SHOW_WHEN)) then
        hide_secondary()
        return
    end

    local scount = count_parameters(sibling)
    local snames = {}
    for p = 1, scount do
        snames[p] = sibling:parameter(p).name
    end
    local sec_index = match_parameter(snames, sec_name)
    if (not sec_index) then
        hide_secondary()
        return
    end

    local sec_param = sibling:parameter(sec_index)
    local sec_choices = parameter_choices(sec_param)
    local sec_labels = {}
    for i, c in ipairs(sec_choices) do
        sec_labels[i] = c.label
    end
    if (selected_devices[row_number]["osig_target_label_sec"] == nil and sec_choices[1]) then
        -- Prefer the resolution already implied by the combined primary label (e.g. the
        -- "Maximum" in "Linear Phase / Maximum") so Minimize/Maximize land on the right
        -- resolution instead of always defaulting to the first choice.
        local initial = sec_choices[1].label
        if (primary_suffix) then
            for _, c in ipairs(sec_choices) do
                if (c.label == primary_suffix) then initial = c.label; break end
            end
        end
        selected_devices[row_number]["osig_target_label_sec"] = initial
    end
    local sec_idx = 1
    local cur = selected_devices[row_number]["osig_target_label_sec"]
    for i, c in ipairs(sec_choices) do
        if (c.label == cur) then
            sec_idx = i
            break
        end
    end
    sec_popup.items = sec_labels
    sec_popup.value = sec_idx
    sec_popup.active = true
    sec_popup.visible = true
    if (sec_label) then
        sec_label.text = sec_name .. ":"
        sec_label.visible = true
    end
    selected_devices[row_number]["secondary_parameter_index"] = sec_index
    selected_devices[row_number]["secondary_parameter_name"] = sec_param.name
    selected_devices[row_number]["secondary_parameter_choices"] = sec_choices
end

function update_secondary(row_number, device_name, device_instances)
    if (selected_devices[row_number] and selected_devices[row_number]["osig_driven"]) then
        update_secondary_osig(row_number, device_name, device_instances)
        return
    end
    local ids = create_settings_row_identifiers(row_number)
    local sec_popup = vb.views[ids["parameter_value_secondary_popup_id"]]
    local sec_label = vb.views[ids["parameter_value_secondary_label_id"]]
    local sec_name = known_secondary(device_name)
    local primary_name = known_primary(device_name)

    local function hide_secondary()
        sec_popup.items = {""}
        sec_popup.value = 1
        sec_popup.active = false
        sec_popup.visible = false
        if (sec_label) then
            sec_label.text = ""
            sec_label.visible = false
        end
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
    if (sec_label) then
        sec_label.text = sec_name .. ":"
        sec_label.visible = true
    end
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
        slider.visible = false
        popup.visible = true
        selected_devices[row_number]["parameter_choices"] = choices
    else
        slider.min = parameter.value_min
        slider.max = parameter.value_max
        slider.value = target_value
        slider.active = true
        popup.visible = false
        slider.visible = true
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

-- Build the value dropdown for a row whose known parameter is NOT exposed by the
-- device itself (VST3). The labels come from a sibling device's parameter choices;
-- the value is applied through the VST3 state-chunk signature. The current label
-- is detected from the live VST3 blob when a signature exists, otherwise the first
-- choice is assumed.
local function show_osig_dropdown(row_number, device_name, device_instances, choices, parameter_name, sibling, sibling_index)
    selected_devices[row_number]["parameter_name"] = parameter_name
    selected_devices[row_number]["parameter_index"] = nil
    selected_devices[row_number]["osig_driven"] = true
    selected_devices[row_number]["sibling_device"] = sibling
    selected_devices[row_number]["sibling_primary_index"] = sibling_index
    selected_devices[row_number]["parameter_choices"] = choices

    local ids = create_settings_row_identifiers(row_number)
    local popup = vb.views[ids["parameter_value_popup_id"]]
    local slider = vb.views[ids["parameter_value_slider_id"]]

    local labels = {}
    for i, c in ipairs(choices) do
        labels[i] = c.label
    end

    local target_label = choices[1] and choices[1].label
    local entries = osig[core.normalize_device_name(device_name)]
    if (entries and #entries > 0) then
        local dev = device_instances[1]
        local ok, blob = pcall(function()
            return dev.active_preset_data
        end)
        if (ok and type(blob) == "string" and blob ~= "") then
            local cur
            if (string.match(blob, "<ParameterChunk>")) then
                cur = core.detect_label_xml(blob, entries)
            else
                cur = core.detect_label(blob, entries)
            end
            if (cur) then
                target_label = cur
            end
        end
    end
    selected_devices[row_number]["osig_target_label"] = target_label

    local idx = 1
    if (selected_devices[row_number]["osig_multi_axis"]) then
        -- target_label is the combined "axis1 / axis2"; the primary popup only shows
        -- axis1, and the secondary popup (filled by update_secondary) shows axis2.
        local axes = selected_devices[row_number]["osig_axes"]
        local a1, a2 = target_label, nil
        if (type(target_label) == "string") then
            local sep = target_label:find(SECONDARY_SEP, 1, true)
            if (sep) then
                a1 = target_label:sub(1, sep - 1)
                a2 = target_label:sub(sep + 3)
            else
                -- No separator: default the second axis to its first (off) label so the
                -- stored target is always the full combined key.
                a2 = axes[2] and axes[2].labels[1]
                target_label = a1 .. SECONDARY_SEP .. (a2 or "")
                selected_devices[row_number]["osig_target_label"] = target_label
            end
        end
        selected_devices[row_number]["osig_axis2_label"] = a2
        for i, c in ipairs(choices) do
            if (c.label == a1) then
                idx = i
                break
            end
        end
    else
        for i, c in ipairs(choices) do
            if (c.label == target_label) then
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
    local device_instances = ensure_device_instances(device_name)
    local device = device_instances[1]
    if (not device) then
        return
    end

    -- VST3 builds expose no host parameter for oversampling; go straight to the
    -- state-chunk signature without enumerating (and matching) the 344 params.
    local norm = core.normalize_device_name(device_name)
    local sig = osig[norm]
    if (sig and #sig > 0 and device_name:sub(1, 5) == "VST3:") then
        local choices = core.osig_choices(norm)
        -- Several independent oversampling fields (e.g. Saturn 2's "High Quality" mode
        -- and "Linear Phase" toggle): present one dropdown per axis. The primary popup
        -- shows the first axis' labels; a separate secondary popup shows the next axis;
        -- the combined signature label (axis1 .. " / " .. axis2) is rebuilt at patch time.
        local axes = core.osig_axes(norm)
        if (axes and #axes >= 2) then
            local mchoices = {}
            for i, l in ipairs(axes[1].labels) do
                mchoices[i] = { label = l, value = i }
            end
            selected_devices[row_number]["osig_multi_axis"] = true
            selected_devices[row_number]["osig_axes"] = axes
            show_osig_dropdown(row_number, device_name, device_instances, mchoices, parameter_name, nil, nil)
            return
        end
        -- Not a multi-axis device: clear any stale multi-axis state left by a previously
        -- selected device so single-axis labels are not treated as combined "axis1 / axis2"
        -- keys (which would then fail to match any signature label).
        selected_devices[row_number]["osig_multi_axis"] = nil
        selected_devices[row_number]["osig_axes"] = nil
        if (not choices) then
            local seen = {}
            local labels = {}
            for _, e in ipairs(sig) do
                for lab in pairs(e.values) do
                    if (not seen[lab]) then
                        seen[lab] = true
                        labels[#labels + 1] = lab
                    end
                end
            end
            table.sort(labels)
            choices = {}
            for i, l in ipairs(labels) do
                choices[i] = { label = l, value = i }
            end
        end
        -- A dependent secondary (e.g. Pro-Q 3's "Processing Resolution") is driven by a
        -- sibling device that exposes the host parameter; pass it through so the secondary
        -- dropdown can appear (update_secondary_osig needs the sibling to read its values).
        local sibling, sibling_index
        local primary_name = known_primary(device_name)
        if (primary_name) then
            sibling = find_sibling_device(device_name, primary_name)
            if (sibling) then
                local scount = count_parameters(sibling)
                local snames = {}
                for p = 1, scount do snames[p] = sibling:parameter(p).name end
                sibling_index = match_parameter(snames, primary_name)
            end
        end
        show_osig_dropdown(row_number, device_name, device_instances, choices, parameter_name, sibling, sibling_index)
        return
    end

    local count = count_parameters(device)
    local names = {}
    for p = 1, count do
        names[p] = device:parameter(p).name
    end

    local parameter_index = match_parameter(names, parameter_name)
    if (parameter_index) then
        selected_devices[row_number]["parameter_name"] = device:parameter(parameter_index).name
        selected_devices[row_number]["parameter_index"] = parameter_index
        selected_devices[row_number]["osig_driven"] = nil
        set_value_control(row_number, device_name, device_instances, parameter_index)
        return
    end

    -- The parameter is not exposed on this device (typical for VST3 builds, which
    -- keep oversampling out of the host-parameter list). Use a built-in
    -- state-chunk signature's labels directly (hardcoded, no sibling needed).
    norm = core.normalize_device_name(device_name)
    local entries = osig[norm]
    -- The osig state-chunk signatures are learned from VST3 builds, which hide
    -- oversampling from the host-parameter list. Only drive them for VST3 devices;
    -- applying a VST3-learned signature to an AU/VST2 build would patch the wrong
    -- bytes (no-op or corruption). Non-VST3 devices expose oversampling as a host
    -- parameter and are handled by the sibling/parameter paths below.
    if (device_name:sub(1, 5) == "VST3:" and entries and #entries > 0) then
        local choices = core.osig_choices(norm)
        if (not choices) then
            local seen = {}
            local labels = {}
            for _, e in ipairs(entries) do
                for lab in pairs(e.values) do
                    if (not seen[lab]) then
                        seen[lab] = true
                        labels[#labels + 1] = lab
                    end
                end
            end
            table.sort(labels)
            choices = {}
            for i, l in ipairs(labels) do
                choices[i] = { label = l, value = i }
            end
        end
        show_osig_dropdown(row_number, device_name, device_instances, choices, parameter_name, nil, nil)
        return
    end
    -- Fallback: borrow labels from a sibling device of the same plugin if present.
    local sibling = find_sibling_device(device_name, parameter_name)
    if (sibling) then
        local scount = count_parameters(sibling)
        local snames = {}
        for p = 1, scount do
            snames[p] = sibling:parameter(p).name
        end
        local sindex = match_parameter(snames, parameter_name)
        if (sindex) then
            -- The value is applied through the VST3 state-chunk signature, so a
            -- signature must exist for this device and it must be a VST3 build. Without a
            -- signature (or for an AU/VST2 build, which apply_osig_to_device_name refuses
            -- to touch) Set cannot apply the selected target, so don't present osig controls.
            local entries = osig[core.normalize_device_name(device_name)]
            if (device_name:sub(1, 5) == "VST3:" and entries and #entries > 0) then
                show_osig_dropdown(row_number, device_name, device_instances,
                    parameter_choices(sibling:parameter(sindex)), parameter_name, sibling, sindex)
                return
            end
        end
    end
    -- Neither a signature nor a sibling provides labels: nothing to drive.
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
    local parameter_label = vb.views[create_settings_row_identifiers(row_number)["parameter_label_id"]]

    -- Known, hard-coded parameter: the parameter is fixed, so replace the dropdown
    -- with a static, right-aligned label (ending in a colon). This also covers VST3
    -- devices whose oversampling is driven purely through the state-chunk signature
    -- (no host parameter is exposed), so no parameter scan is needed.
    if (known_primary_name) then
        parameters_popup.visible = false
        parameter_label.text = known_primary_name .. ":"
        parameter_label.visible = true
        apply_parameter_value(row_number, device_name, known_primary_name)
        mark_parameter_scan_finished()
        set_main_buttons_active(true)
        return
    end

    -- Unknown device: show the dropdown (and hide the label) and scan its parameters.
    parameter_label.visible = false
    parameters_popup.visible = true

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
            elseif (osig[core.normalize_device_name(device_name)]) then
                -- VST3 host builds don't expose the oversampling parameter, so it is
                -- not in the enumerated list. Re-establish the state-chunk dropdown
                -- (the value popup) so the oversampling choices stay visible after
                -- the full scan has overwritten the parameter popup.
                apply_parameter_value(row_number, device_name, known_primary_name)
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
                -- For VST3 plugins whose oversampling is not a host parameter, set
                -- the intended dropdown label (first = minimum, last = maximum) so
                -- set_values() can drive the state chunk to that exact value.
                if (selected_device["osig_driven"] and osig[core.normalize_device_name(device_name)]) then
                    if (selected_device["osig_multi_axis"]) then
                        -- Minimum/Maximum spans both independent axes: both off for the
                        -- minimum, both at their highest for the maximum.
                        local axes = selected_device["osig_axes"]
                        local a1 = axes[1].labels
                        local a2 = axes[2].labels
                        local c1 = (extreme == "min") and a1[1] or a1[#a1]
                        local c2 = (extreme == "min") and a2[1] or a2[#a2]
                        selected_device["osig_target_label"] = c1 .. SECONDARY_SEP .. c2
                        selected_device["osig_axis2_label"] = c2
                    else
                        local choices = selected_device["parameter_choices"]
                        if (choices and #choices > 0) then
                            selected_device["osig_target_label"] =
                                (extreme == "min") and choices[1].label or choices[#choices].label
                            local sec_popup = vb.views[create_settings_row_identifiers(row_number)["parameter_value_secondary_popup_id"]]
                            if (sec_popup and sec_popup.visible) then
                                local sch = selected_device["secondary_parameter_choices"]
                                if (sch and #sch > 0) then
                                    selected_device["osig_target_label_sec"] =
                                        (extreme == "min") and sch[1].label or sch[#sch].label
                                end
                            else
                                selected_device["osig_target_label_sec"] = nil
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
            if (selected_devices[row_number]["osig_driven"]) then
                local ids = create_settings_row_identifiers(row_number)
                local popup = vb.views[ids["parameter_value_popup_id"]]
                local choices = selected_devices[row_number]["parameter_choices"]
                local target_label = selected_devices[row_number]["osig_target_label"]
                local idx = 1
                if (selected_devices[row_number]["osig_multi_axis"]) then
                    -- target_label is the combined "axis1 / axis2"; show axis1 in the
                    -- primary popup and let update_secondary place axis2 in the secondary.
                    local axes = selected_devices[row_number]["osig_axes"]
                    local a1, a2 = target_label, nil
                    if (type(target_label) == "string") then
                        local sep = target_label:find(SECONDARY_SEP, 1, true)
                        if (sep) then
                            a1 = target_label:sub(1, sep - 1)
                            a2 = target_label:sub(sep + 3)
                        end
                    end
                    selected_devices[row_number]["osig_axis2_label"] = a2
                    if (choices) then
                        for i, c in ipairs(choices) do
                            if (c.label == a1) then
                                idx = i
                                break
                            end
                        end
                    end
                elseif (choices and target_label) then
                    for i, c in ipairs(choices) do
                        if (c.label == target_label) then
                            idx = i
                            break
                        end
                    end
                end
                if (popup) then
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

--------------------------------------------------------------------------------
-- VST3 state-chunk fallback.
--
-- When a device's oversampling is not exposed as a host parameter (so there is no
-- parameter_index to drive) but a calibration signature exists, flip the learned
-- bytes directly in the plugin's raw 'active_preset_data' blob. Returns the number
-- of device instances whose state chunk was actually changed; blobs already at the
-- target are a successful no-op and are not counted.

local function apply_osig_to_device_name(device_name, target, state)
  -- osig state-chunk signatures are VST3-only; applying them to an AU/VST2 build
  -- would patch the wrong bytes. Guard here as the last line of defense even though
  -- the UI only marks rows osig_driven for VST3 devices.
  if (device_name:sub(1, 5) ~= "VST3:") then
    return 0
  end
  local norm = core.normalize_device_name(device_name)
  local entries = osig[norm]
  if (not entries or #entries == 0) then
    return 0
  end
  -- Renoise caches a VST3 plugin's serialized state; refresh it from the live GUI
  -- (by saving first) so we patch the current state and never revert the user's
  -- other settings. Guarded so an unsaved song never triggers a save dialog.
  -- `state.saved` ensures the song is refreshed at most once across all osig rows
  -- applied in a single Set action.
  local song = renoise.song()
  if (not state.saved and song.file_name and song.file_name ~= "") then
    pcall(function() song:save() end)
    state.saved = true
  end
  -- "toggle" resolves to a concrete label: detect the current value, then step to
  -- the next one in the device's natural oversampling order (cyclic). This keeps a
  -- single toggle button useful even though oversampling is now multi-valued.
  if (target == "toggle") then
    local dev0 = ensure_device_instances(device_name)[1]
    local cur = nil
    if (dev0) then
      local ok, blob = pcall(function() return dev0.active_preset_data end)
      if (ok and type(blob) == "string" and blob ~= "") then
        if (string.match(blob, "<ParameterChunk>")) then
          cur = core.detect_label_xml(blob, entries)
        else
          cur = core.detect_label(blob, entries)
        end
      end
    end
    -- Prefer the device's explicit oversampling order (e.g. 2x before 16x); only fall
    -- back to alphabetical sorting when no natural order is defined.
    local ordered
    local oc = core.osig_choices(norm)
    if (oc) then
      ordered = {}
      for i, c in ipairs(oc) do
        ordered[#ordered + 1] = c.label
      end
    else
      local labels = {}
      for _, e in ipairs(entries) do
        for lab in pairs(e.values) do
          labels[lab] = true
        end
      end
      ordered = {}
      for lab in pairs(labels) do
        ordered[#ordered + 1] = lab
      end
      table.sort(ordered)
    end
    if (cur) then
      for i, lab in ipairs(ordered) do
        if (lab == cur) then
          target = ordered[(i % #ordered) + 1]
          break
        end
      end
    else
      target = ordered[1]
    end
  end
  local instances = ensure_device_instances(device_name)
  local changed = 0
  for _, dev in ipairs(instances) do
    local ok, xml = pcall(function() return dev.active_preset_data end)
    if (ok and type(xml) == "string" and xml ~= "") then
      local is_xml = string.match(xml, "<ParameterChunk>")
      -- Fail closed: only patch when the current chunk is a recognized oversampling
      -- state for this device. After a plugin update or with a stale signature the
      -- learned bytes no longer describe the real state, and writing the target would
      -- overwrite unrelated bytes; skipping keeps the device intact.
      local cur = is_xml and core.detect_label_xml(xml, entries) or core.detect_label(xml, entries)
      if (not cur) then
        print("OVERSAMPLE osig apply skipped for '" .. tostring(device_name)
          .. "': current state is not a recognized oversampling signature")
      else
        local newdata
        if (is_xml) then
          -- patch_osig_xml returns nil only when the target bytes already match the
          -- current state (no change needed — e.g. two oversampling labels that
          -- serialize to identical chunks). That is a successful no-op, not an error.
          newdata = core.patch_osig_xml(xml, entries, target)
        else
          newdata = core.patch_blob(xml, entries, target)
        end
        if (newdata and newdata ~= xml) then
          local ok2, err = pcall(function()
            dev.active_preset_data = newdata
          end)
          if (ok2) then
            changed = changed + 1
          else
            print("OVERSAMPLE osig apply failed for '" .. tostring(device_name) .. "': " .. tostring(err))
          end
        end
      end
    end
  end
  return changed
end

function set_values()
    set_main_buttons_active(false)
    local parameters_changed = 0
    -- Shared across osig rows so the VST3 state-refresh save happens once per Set.
    local osig_save_state = { saved = false }

    for row_number, selected_device in ipairs(selected_devices) do
        local device_name = selected_device["device_name"]
        local parameter_name = selected_device["parameter_name"]
        local parameter_value = selected_device["parameter_value"]
        local device_instances = ensure_device_instances(device_name)

        if (parameter_value == nil) then
            parameter_value = 0
        end

        -- VST3 fallback: when the oversampling parameter is not exposed by the plugin
        -- (so there is no parameter_index to drive) but we have a learned state-chunk
        -- signature, set the exact value directly in the raw preset data instead.
        local param_index = selected_device["parameter_index"]
        if (selected_device["osig_driven"]) then
            local target = osig_target_for_row(row_number) or "toggle"
            parameters_changed = parameters_changed + apply_osig_to_device_name(device_name, target, osig_save_state)
        elseif (param_index ~= nil) then
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
    end

    local verb = nil
    local button_text = nil

    vb.views.status.text = parameters_changed .. ' parameter values set.'
    set_main_buttons_active(true)
end
