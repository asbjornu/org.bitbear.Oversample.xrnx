--[[============================================================================
Oversample/oversample_core.lua

Pure, Renoise-independent data-manipulation and helper logic for the Oversample
tool, extracted from Oversample.lua so it can be unit-tested in isolation with a
plain Lua interpreter (see test/oversample_core_test.lua).

This module intentionally has NO dependency on `renoise`, `vb` (ViewBuilder) or
the `class` helper. Every function operates only on plain Lua tables passed in
as arguments and never touches global UI state.
============================================================================]]--

local core = {}


--------------------------------------------------------------------------------
-- Mapping of device names to the quality-related parameter(s) we want to
-- preselect. A value is either a single parameter name (string) or a list of
-- parameter names (table).

core.known_devices_parameters = {
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

    ['VST3: FabFilter: Pro-Q 2'] = {
       'Processing Mode', 'Processing Resolution'
    },
    ['VST3: FabFilter: Pro-Q 3'] = {
       'Processing Mode', 'Processing Resolution'
    },
}


--------------------------------------------------------------------------------
-- The recognised primary parameter name for a device (the one we snap to and
-- drive). Works for string, list, and table style known_devices_parameters.

function core.known_primary(device_name)
   local kp = core.known_devices_parameters[device_name]
   if (not kp) then
      return nil
   end
   if (type(kp) == "string") then
      return kp
   end
   if (type(kp) == "table") then
      if (kp.primary) then
         return kp.primary
      end
      return kp[1]
   end
   return nil
end


--------------------------------------------------------------------------------
-- The recognised dependent secondary parameter name (e.g. Pro-Q's
-- "Processing Resolution"), if the device declares one.

function core.known_secondary(device_name)
   local kp = core.known_devices_parameters[device_name]
   if (type(kp) == "table") then
      if (kp.secondary) then
         return kp.secondary.name
      end
      if (kp[2]) then
         return kp[2]
      end
   end
   return nil
end


--------------------------------------------------------------------------------
-- Build the identifiers used for a settings row's views. Pure string builder.

function core.create_settings_row_identifiers(row_number)
   return {
      ["device_popup_id"] = "devices_popup_" .. row_number,
      ["parameter_popup_id"] = "parameters_popup_" .. row_number,
      ["parameter_value_popup_id"] = "parameter_value_popup_" .. row_number,
      ["parameter_value_slider_id"] = "parameter_value_slider_" .. row_number,
      ["parameter_value_secondary_popup_id"] = "parameter_value_secondary_popup_" .. row_number,
      ["settings_row_id"] = "settings_row_" .. row_number,
      ["add_button_id"] = "add_button_" .. row_number
   }
end


--------------------------------------------------------------------------------
-- Cache (de)serialization.
--
-- A per-device cache entry is stored as a length-prefixed, fully printable
-- string ("<len>;<value>" blocks concatenated). The length prefix means device
-- or parameter names may themselves contain ';' without breaking the encoding.

function core.encode_field(str)
   return string.len(str) .. ";" .. str
end

function core.decode_fields(str)
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


--------------------------------------------------------------------------------
-- Resolve a known parameter name to its index within a list of parameter names.
-- Plugins do not always expose the exact name we expect, so we match exactly
-- first, then case-insensitively (ignoring surrounding whitespace), then by
-- substring (the known name appearing inside the real name). Returns nil when
-- nothing matches.

function core.match_parameter(names, target)
   local tl = tostring(target):lower():match("^%s*(.-)%s*$")

   for i, n in ipairs(names) do
      if (n == target) then
         return i
      end
   end
   for i, n in ipairs(names) do
      if (tostring(n):lower():match("^%s*(.-)%s*$") == tl) then
         return i
      end
   end
   for i, n in ipairs(names) do
      if (tostring(n):lower():find(tl, 1, true)) then
         return i
      end
   end
   return nil
end


--------------------------------------------------------------------------------
-- True when two lists contain the same set of names, ignoring order.

function core.same_name_set(a, b)
   if (#a ~= #b) then return false end
   local seen = {}
   for _, v in ipairs(a) do seen[v] = true end
   for _, v in ipairs(b) do
      if (not seen[v]) then return false end
   end
   return true
end


--------------------------------------------------------------------------------
-- Build the device dropdown items from either the live `devices` map (when it
-- has been scanned) or the persisted `cached_device_names` list otherwise.

function core.collect_device_items(devices, cached_device_names)
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
   return device_items
end


--------------------------------------------------------------------------------
-- Resolve the parameter index to apply, preferring a known parameter name when
-- present. `parameter_names` is the device's full parameter-name list; falls
-- back to the already-known `parameter_index` when the name is absent.

function core.resolve_parameter_index(parameter_names, parameter_name, parameter_index)
   if (parameter_name) then
      for p = 1, #parameter_names do
         if (parameter_names[p] == parameter_name) then
            return p
         end
      end
   end
   return parameter_index
end



--------------------------------------------------------------------------------
-- Index of the choice whose value is closest to `value`. Enumeration stepping in
-- a parameter's choice list can record the maximum a hair below the plugin's
-- true value_max, so an exact match can fail and wrongly fall back to the first
-- item. Picking the nearest value is robust to that floating-point discrepancy.
-- `choices` is an array of tables each exposing a numeric `value` field.

function core.nearest_choice_index(choices, value)
   local idx = 1
   local best = math.huge
   for i, c in ipairs(choices) do
      local d = math.abs((c.value or 0) - value)
      if (d < best) then
         best = d
         idx = i
      end
   end
   return idx
end


--------------------------------------------------------------------------------
-- Resolve the exact parameter indices to drive for a given device row, so that
-- "set to min/max" touches ONLY the known oversampling parameter(s) plus the
-- row's selected primary/secondary parameter, and never every parameter.
--
-- `parameter_names` is the device's full list of parameter name strings
-- (1-based, parallel to the device's parameter indices). `device_name` selects
-- the known primary/secondary from known_devices_parameters, and `selected` is
-- the row's selection table with optional `parameter_name`/`parameter_index`
-- and `secondary_parameter_name`/`secondary_parameter_index`. Returns an array
-- of 1-based indices with no duplicates.

function core.resolve_target_indices(parameter_names, device_name, selected)
   local targets = {}
   local seen = {}
   local count = #parameter_names

   local function add(idx)
      if (idx and idx >= 1 and idx <= count and not seen[idx]) then
         seen[idx] = true
         targets[#targets + 1] = idx
      end
   end

   local function add_by_name(name)
      if (name) then
         local i = core.match_parameter(parameter_names, name)
         if (i) then add(i) end
      end
   end

   add_by_name(core.known_primary(device_name))
   add_by_name(core.known_secondary(device_name))

   if (selected and selected.parameter_name) then
      add_by_name(selected.parameter_name)
   else
      add(selected and selected.parameter_index)
   end

   if (selected and selected.secondary_parameter_name) then
      add_by_name(selected.secondary_parameter_name)
   else
      add(selected and selected.secondary_parameter_index)
   end

   return targets
end


return core
