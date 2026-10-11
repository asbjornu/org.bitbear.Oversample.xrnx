-- Pure, Renoise-independent helpers live in the shared core module so they can be
-- unit-tested in isolation. Alias them here to keep the call sites below unchanged.
local core = require("oversample/core")
local same_name_set = core.same_name_set

-- All mutable runtime state lives in one injected table (see oversample/state.lua).
local state = require("oversample/state")(renoise)
local cache = require("oversample/cache")({ renoise = renoise, core = core, state = state })
local list_count = cache.list_count

-- Every function below is a module-local. These forward declarations exist only
-- so mutually recursive helpers can be referenced before they are defined; the
-- definitions use `function name(...)` and assign to the local.
local on_song_devices_changed, oversample_on_new_song, oversample_init
local oversample, destroy
local set_main_buttons_active
local set_values

local vb = renoise.ViewBuilder()

-- Song scanning/instances live in oversample/devices.lua; the UI callbacks are
-- injected as closures over the coordinator's forward-declared locals.
local devices = require("oversample/devices")({
    renoise = renoise,
    core = core,
    state = state,
    list_count = list_count,
    -- ProcessSlicer is a Renoise global installed by main.lua *after* this module
    -- is required, so resolve it lazily inside the callback rather than reading the
    -- undeclared global at load time.
    process_slicer = function(...) return ProcessSlicer(...) end,
    ui = {
        vb = vb,
        set_main_buttons_active = function(active) set_main_buttons_active(active) end,
        on_song_devices_changed = function() on_song_devices_changed() end,
    },
})

-- Oversampling-signature labels + VST3 chunk patching live in oversample/osig.lua.
local osig = require("oversample/osig")({
    renoise = renoise,
    core = core,
    state = state,
    devices = devices,
})

-- The dialog historically called this with no argument, meaning "the current row
-- count". The pure core builder requires a row number, so supply the default here.
local function create_settings_row_identifiers(row_number)
   return core.create_settings_row_identifiers(row_number or state.settings_row_count)
end

-- Tracks in-flight per-device parameter scans so the status text only reports
-- "Done." once every background scan has actually finished (each row's default
-- device triggers its own asynchronous enumeration via ProcessSlicer).
local function mark_parameter_scan_started()
    state.pending_parameter_scans = state.pending_parameter_scans + 1
    vb.views.status.text = string.format('Finding parameters... (%d)', state.pending_parameter_scans)
end
local function mark_parameter_scan_finished()
    if state.pending_parameter_scans > 0 then
        state.pending_parameter_scans = state.pending_parameter_scans - 1
    end
    if state.pending_parameter_scans == 0 then
        vb.views.status.text = 'Done.'
    else
        vb.views.status.text = string.format('Finding parameters... (%d)', state.pending_parameter_scans)
    end
end

-- Per-row parameter/secondary state machine lives in oversample/parameters.lua.
local parameters = require("oversample/parameters")({
    core = core,
    state = state,
    osig = osig,
    devices = devices,
    vb = vb,
    create_settings_row_identifiers = create_settings_row_identifiers,
    set_main_buttons_active = function(active) set_main_buttons_active(active) end,
    mark_parameter_scan_started = mark_parameter_scan_started,
    mark_parameter_scan_finished = mark_parameter_scan_finished,
    process_slicer = function(...) return ProcessSlicer(...) end,
})

-- The dialog shell, fixed column widths, and the settings-grid view construction
-- live in oversample/layout.lua. It receives the shared ViewBuilder and the
-- parameter module's callbacks.
local layout = require("oversample/layout")({
    renoise = renoise,
    core = core,
    state = state,
    cache = cache,
    devices = devices,
    osig = osig,
    vb = vb,
    create_settings_row_identifiers = create_settings_row_identifiers,
    set_main_buttons_active = function(active) set_main_buttons_active(active) end,
    handlers = {
        device_selected = parameters.device_selected,
        parameter_selected = parameters.parameter_selected,
        parameter_value_changed = parameters.parameter_value_changed,
        update_secondary = parameters.update_secondary,
        extreme_values = parameters.extreme_values,
        set_values = function(...) return set_values(...) end,
    },
})


-- The persistent parameter/device/oversampling-signature cache lives in
-- oversample/cache.lua; the coordinator only calls its load/save/prune API.


on_song_devices_changed = function()
  cache.prune_parameter_cache()
  state.devices_valid = false
  state.cached_device_names = devices.collect_device_names()
  state.device_names_dirty = true
  state.global_device_names_dirty = true
  cache.save_global_device_name_cache()
  layout.refresh_device_popups()
  layout.add_rows_for_new_known_devices()
end


-- Reset all per-song state when a new song is loaded, then reload the cache.
function oversample_on_new_song()
  state.devices = {}
  state.selected_devices = {}
  state.settings_row_count = 0
  state.devices_valid = false

  cache.load_tool_cache()
  devices.attach_song_device_notifiers()
end

-- Called once from main.lua when the tool is loaded.
function oversample_init()
  if state.initialized then
    return
  end
  state.initialized = true

  cache.load_tool_cache()

  -- The device notifiers need a live song, which may not exist yet while the tool
  -- is being loaded at Renoise startup (before the initial song is created). Defer
  -- them (and the per-song cache load) until a song is available.
  local function init_song_dependencies()
    cache.load_tool_cache()
    devices.attach_song_device_notifiers()
  end

  if renoise.song() then
    init_song_dependencies()
  else
    local idle_notifier
    idle_notifier = function()
      if renoise.song() then
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
    if state.cache_dirty or state.device_names_dirty then
      cache.save_tool_cache()
    end
    if state.global_cache_dirty then
      cache.save_global_cache()
    end
    if state.global_device_names_dirty then
      cache.save_global_device_name_cache()
    end
  end)

  renoise.tool().app_new_document_observable:add_notifier(oversample_on_new_song)
end

function oversample()
    if state.dialog then
        destroy()
    end

    state.pending_parameter_scans = 0

    local dialog_view = layout.build_dialog_view()

    state.dialog = renoise.app():show_custom_dialog("Oversample", dialog_view)

    if state.devices_valid then
        -- In-session cache (instances already collected): rebuild instantly.
        layout.add_device_items_init()
        return
    end

    local live_names = devices.collect_device_names()
    if #state.cached_device_names > 0 and same_name_set(state.cached_device_names, live_names) then
        -- Reconciled with the live song: show the cached device list now and
        -- resolve the (cheap) live instances lazily when the user interacts.
        state.cached_device_names = live_names
        state.devices_valid = true
        layout.render_settings_rows(live_names)
        -- Per-row parameter scans may still be running in the background.
        if state.pending_parameter_scans == 0 then
            vb.views.status.text = 'Done.'
        end
        return
    end

    -- Names unavailable or out of date: run the one-time scan to collect live
    -- instances and reconcile against the persisted list.
    vb.views.status.text = 'Finding devices...'

    state.devices = {}
    state.selected_devices = {}
    state.settings_row_count = 0

    local slicer = ProcessSlicer(devices.enumerate_tracks, layout.add_device_items_init)
    slicer:start()
end

function destroy()
    if state.dialog then
        pcall(function() state.dialog:close() end)
    end
    state.dialog = nil

    -- Unregister the per-row views explicitly: the viewbuilder keeps a flat
    -- id registry, so without this the fixed ids (devices_popup_1, ...) would
    -- collide when the dialog is rebuilt on the next open.
    for i = 1, state.settings_row_count do
        local ids = create_settings_row_identifiers(i)
        vb.views[ids.device_popup_id] = nil
        vb.views[ids.parameter_popup_id] = nil
        vb.views[ids.parameter_label_id] = nil
        vb.views[ids.parameter_value_popup_id] = nil
        vb.views[ids.parameter_value_slider_id] = nil
        vb.views[ids.parameter_value_secondary_popup_id] = nil
        vb.views[ids.parameter_value_secondary_label_id] = nil
        vb.views[ids.settings_row_id] = nil
        vb.views[ids.add_button_id] = nil
    end

    vb.views.set_values_button = nil
    vb.views.minimize_values_button = nil
    vb.views.maximize_values_button = nil
    vb.views.status = nil
    vb.views.settings_container = nil
    vb.views["org.bitbear.Oversample"] = nil
end

-- Enable/disable the three action buttons (Set, Minimize, Maximize) together,
-- mirroring the "Set" button's active state used while scans are in flight.
-- Declared local (forward-declared above) because it is invoked from several
-- top-level functions (enumerate_tracks, enumerate_devices, and the layout
-- module) that are defined before this point.
function set_main_buttons_active(active)
    if not vb or not vb.views then
        return
    end
    for _, id in ipairs({ "set_values_button", "minimize_values_button", "maximize_values_button" }) do
        local view = vb.views[id]
        if view then
            pcall(function()
                view.active = active
            end)
        end
    end

    -- Disable every control in the grid while an action (Set/Minimize/Maximize) or a
    -- background scan is in flight, so the user can't edit rows mid-operation.
    for r = 1, state.settings_row_count do
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
            if view then
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
    -- Shared across osig rows so the VST3 state-refresh save happens once per Set.
    local osig_save_state = { saved = false }

    for row_number, selected_device in ipairs(state.selected_devices) do
        local device_name = selected_device.device_name
        local parameter_name = selected_device.parameter_name
        local parameter_value = selected_device.parameter_value
        local device_instances = devices.ensure_device_instances(device_name)

        if parameter_value == nil then
            parameter_value = 0
        end

        -- VST3 fallback: when the oversampling parameter is not exposed by the plugin
        -- (so there is no parameter_index to drive) but we have a learned state-chunk
        -- signature, set the exact value directly in the raw preset data instead.
        local param_index = selected_device.parameter_index
        if selected_device.osig_driven then
            local target = osig.osig_target_for_row(row_number) or "toggle"
            parameters_changed = parameters_changed
                + osig.apply_osig_to_device_name(device_name, target, osig_save_state)
        elseif param_index ~= nil then
            for _, device in ipairs(device_instances) do
                -- Resolve by name when known: robust to index drift and to the
                -- "known parameter shown first" fast path, where the index is only
                -- valid within the short known-only list.
                local parameter_names = devices.parameter_names(device)
                local count = #parameter_names
                local parameter_index = core.resolve_parameter_index(
                    parameter_names, parameter_name, selected_device.parameter_index)

                if parameter_index and parameter_index >= 1 and parameter_index <= count then
                    device:parameter(parameter_index):record_value(parameter_value)
                    parameters_changed = parameters_changed + 1
                end

                -- Apply the dependent secondary parameter (e.g. Pro-Q's
                -- "Processing Resolution"), resolved by name for robustness.
                local sec_value = selected_device.secondary_parameter_value
                if selected_device.secondary_parameter_index and sec_value ~= nil then
                    local sidx = core.resolve_parameter_index(
                        parameter_names, selected_device.secondary_parameter_name,
                        selected_device.secondary_parameter_index)
                    if sidx and sidx >= 1 and sidx <= count then
                        device:parameter(sidx):record_value(sec_value)
                        parameters_changed = parameters_changed + 1
                    end
                end
            end
        end
    end

    vb.views.status.text = parameters_changed .. ' parameter values set.'
    set_main_buttons_active(true)
end

-- Public API consumed by main.lua.
local Oversample = {
    oversample_init = oversample_init,
    oversample = oversample,
}

-- White-box surface driven directly by test/oversample_ui_test.lua.
Oversample.destroy = destroy
Oversample.load_tool_cache = cache.load_tool_cache
Oversample.save_tool_cache = cache.save_tool_cache
Oversample.create_settings_row = layout.create_settings_row
Oversample.update_secondary = parameters.update_secondary
Oversample.device_selected = parameters.device_selected
Oversample.parameter_selected = parameters.parameter_selected
Oversample.refresh_device_popups = layout.refresh_device_popups
Oversample.add_device_items = layout.add_device_items
Oversample.set_main_buttons_active = set_main_buttons_active
Oversample.set_values = set_values

-- Internal seams the UI tests drive directly. Grouped under `_internals` so the
-- public/white-box API above stays uncluttered and the tests do not have to walk
-- the module's upvalue graph.
Oversample._internals = {
    state = state,
    devices = devices,
    osig = osig,
    parameter_choices = parameters.parameter_choices,
    apply_value_to_control = parameters.apply_value_to_control,
    show_osig_dropdown = parameters.show_osig_dropdown,
    apply_parameter_value = parameters.apply_parameter_value,
    update_secondary_osig = parameters.update_secondary_osig,
}

return Oversample
