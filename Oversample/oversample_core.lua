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

-- Keys are the *plugin identity* with the format prefix (VST/VST3/AU/…) stripped,
-- so a single entry matches every plugin format. See normalize_device_name.
core.known_devices_parameters = {
   ['FabFilter: Saturn'] = 'High Quality',
   ['FabFilter: Saturn 2'] = 'High Quality Mode',
   ['FabFilter: Pro-MB'] = 'Oversampling',
   ['FabFilter: Pro-C 2'] = 'Oversampling',
   ['FabFilter: Pro-L 2'] = 'Oversampling',
   ['FabFilter: Pro-Q 2'] = {
      'Processing Mode', 'Processing Resolution'
   },
    ['FabFilter: Pro-Q 3'] = {
       'Processing Mode', 'Processing Resolution'
    },
}

-- Built-in state-chunk oversampling signatures for FabFilter VST3 plugins whose
-- oversampling is not exposed as a host parameter. Each entry is a list of
-- { pos = 1-based byte offset, values = { [label] = byte } }. The bytes were learned
-- by diffing saved .xrns Song.xml ParameterChunk blobs across every oversampling
-- value; every source->target patch reproduces the exact saved chunk. Pro-Q 3 uses
-- 5 bytes (mode 1311/1312, resolution 1315/1316, flag 1554); Pro-C 2 / Pro-L 2 use 2
-- bytes; Pro-MB uses 4; Saturn 2 uses 5. Labels match the dropdown strings the tool
-- shows for each device.
core.known_osig = {
   ['FabFilter: Pro-Q 3'] = {
      { pos = 1311, values = {
            ['Zero Latency'] = 0x00, ['Natural Phase'] = 0x80,
            ['Linear Phase / Low'] = 0x00, ['Linear Phase / Medium'] = 0x00,
            ['Linear Phase / High'] = 0x00, ['Linear Phase / Very High'] = 0x00,
            ['Linear Phase / Maximum'] = 0x00 } },
      { pos = 1312, values = {
            ['Zero Latency'] = 0x00, ['Natural Phase'] = 0x3f,
            ['Linear Phase / Low'] = 0x40, ['Linear Phase / Medium'] = 0x40,
            ['Linear Phase / High'] = 0x40, ['Linear Phase / Very High'] = 0x40,
            ['Linear Phase / Maximum'] = 0x40 } },
      { pos = 1315, values = {
            ['Zero Latency'] = 0x80, ['Natural Phase'] = 0x80,
            ['Linear Phase / Low'] = 0x00, ['Linear Phase / Medium'] = 0x80,
            ['Linear Phase / High'] = 0x00, ['Linear Phase / Very High'] = 0x40,
            ['Linear Phase / Maximum'] = 0x80 } },
      { pos = 1316, values = {
            ['Zero Latency'] = 0x3f, ['Natural Phase'] = 0x3f,
            ['Linear Phase / Low'] = 0x00, ['Linear Phase / Medium'] = 0x3f,
            ['Linear Phase / High'] = 0x40, ['Linear Phase / Very High'] = 0x40,
            ['Linear Phase / Maximum'] = 0x40 } },
      { pos = 1554, values = {
            ['Zero Latency'] = 0x00, ['Natural Phase'] = 0x01,
            ['Linear Phase / Low'] = 0x01, ['Linear Phase / Medium'] = 0x01,
            ['Linear Phase / High'] = 0x01, ['Linear Phase / Very High'] = 0x01,
            ['Linear Phase / Maximum'] = 0x01 } },
   },
   ['FabFilter: Pro-C 2'] = {
      { pos = 246, values = {
            ['Off'] = 0x00, ['2x'] = 0x80, ['4x'] = 0x00 } },
      { pos = 247, values = {
            ['Off'] = 0x00, ['2x'] = 0x3f, ['4x'] = 0x40 } },
   },
   ['FabFilter: Pro-L 2'] = {
      { pos = 122, values = {
            ['Off'] = 0x00, ['2x'] = 0x80, ['4x'] = 0x00,
            ['8x'] = 0x40, ['16x'] = 0x80, ['32x'] = 0xa0 } },
      { pos = 123, values = {
            ['Off'] = 0x00, ['2x'] = 0x3f, ['4x'] = 0x40,
            ['8x'] = 0x40, ['16x'] = 0x40, ['32x'] = 0x40 } },
   },
   ['FabFilter: Pro-MB'] = {
      { pos = 642, values = {
            ['Dynamic Phase / Off'] = 0x80, ['Dynamic Phase / 2x'] = 0x80, ['Dynamic Phase / 4x'] = 0x80,
            ['Linear Phase / Off'] = 0x00, ['Linear Phase / 2x'] = 0x00, ['Linear Phase / 4x'] = 0x00,
            ['Minimum Phase / Off'] = 0x00, ['Minimum Phase / 2x'] = 0x00, ['Minimum Phase / 4x'] = 0x00 } },
      { pos = 643, values = {
            ['Dynamic Phase / Off'] = 0x3f, ['Dynamic Phase / 2x'] = 0x3f, ['Dynamic Phase / 4x'] = 0x3f,
            ['Linear Phase / Off'] = 0x00, ['Linear Phase / 2x'] = 0x00, ['Linear Phase / 4x'] = 0x00,
            ['Minimum Phase / Off'] = 0x40, ['Minimum Phase / 2x'] = 0x40, ['Minimum Phase / 4x'] = 0x40 } },
      { pos = 646, values = {
            ['Dynamic Phase / Off'] = 0x00, ['Dynamic Phase / 2x'] = 0x80, ['Dynamic Phase / 4x'] = 0x00,
            ['Linear Phase / Off'] = 0x00, ['Linear Phase / 2x'] = 0x80, ['Linear Phase / 4x'] = 0x00,
            ['Minimum Phase / Off'] = 0x00, ['Minimum Phase / 2x'] = 0x80, ['Minimum Phase / 4x'] = 0x00 } },
      { pos = 647, values = {
            ['Dynamic Phase / Off'] = 0x00, ['Dynamic Phase / 2x'] = 0x3f, ['Dynamic Phase / 4x'] = 0x40,
            ['Linear Phase / Off'] = 0x00, ['Linear Phase / 2x'] = 0x3f, ['Linear Phase / 4x'] = 0x40,
            ['Minimum Phase / Off'] = 0x00, ['Minimum Phase / 2x'] = 0x3f, ['Minimum Phase / 4x'] = 0x40 } },
   },
   -- Saturn 2 exposes two *independent* oversampling controls in its chunk (they are
   -- not VST3 host parameters): a "Linear Phase" On/Off toggle and a "High Quality"
   -- mode (Off / Good / Superb). The saved .xrns songs are the four corners of these
   -- two axes; the bytes occupy disjoint positions (Linear Phase: 2847/2848, High
   -- Quality: 2855/2856) so every combination is valid. Position 3916 is a derived
   -- flag that is 0x00 only when BOTH controls are Off, otherwise 0x01. The labels
   -- below are combined as "HighQuality / LinearPhase" so the dropdown lets the two
   -- axes be set independently (e.g. "Good / On" sets High Quality = Good and Linear
   -- Phase = On). The four corner songs verify exactly; the two extra combos are the
   -- disjoint-byte union of the two fields.
   ['FabFilter: Saturn 2'] = {
      { pos = 2847, values = {
            ['Off / Off'] = 0x00, ['Good / Off'] = 0x00, ['Superb / Off'] = 0x00,
            ['Off / On'] = 0x80, ['Good / On'] = 0x80, ['Superb / On'] = 0x80 } },
      { pos = 2848, values = {
            ['Off / Off'] = 0x00, ['Good / Off'] = 0x00, ['Superb / Off'] = 0x00,
            ['Off / On'] = 0x3f, ['Good / On'] = 0x3f, ['Superb / On'] = 0x3f } },
      { pos = 2855, values = {
            ['Off / Off'] = 0x00, ['Good / Off'] = 0x80, ['Superb / Off'] = 0x00,
            ['Off / On'] = 0x00, ['Good / On'] = 0x80, ['Superb / On'] = 0x00 } },
      { pos = 2856, values = {
            ['Off / Off'] = 0x00, ['Good / Off'] = 0x3f, ['Superb / Off'] = 0x40,
            ['Off / On'] = 0x00, ['Good / On'] = 0x3f, ['Superb / On'] = 0x40 } },
      { pos = 3916, values = {
            ['Off / Off'] = 0x00, ['Good / Off'] = 0x01, ['Superb / Off'] = 0x01,
            ['Off / On'] = 0x01, ['Good / On'] = 0x01, ['Superb / On'] = 0x01 } },
   },
}

-- The labels a plugin presents for its oversampling control, in the plugin's own
-- natural (ascending) order: lowest oversampling first, highest last. This order is
-- what the value dropdown shows and what "Minimum"/"Maximum" select (index 1 and
-- index #labels respectively). It must NOT be derived by alphabetically sorting the
-- labels, since that scrambles magnitudes (e.g. "16x" < "2x" < "32x" < "4x" ...).
core.known_osig_order = {
   ['FabFilter: Pro-Q 3'] = {
      'Zero Latency', 'Natural Phase',
      'Linear Phase / Low', 'Linear Phase / Medium', 'Linear Phase / High',
      'Linear Phase / Very High', 'Linear Phase / Maximum' },
   ['FabFilter: Pro-C 2'] = { 'Off', '2x', '4x' },
   ['FabFilter: Pro-L 2'] = { 'Off', '2x', '4x', '8x', '16x', '32x' },
   ['FabFilter: Pro-MB'] = {
      'Dynamic Phase / Off', 'Dynamic Phase / 2x', 'Dynamic Phase / 4x',
      'Linear Phase / Off', 'Linear Phase / 2x', 'Linear Phase / 4x',
      'Minimum Phase / Off', 'Minimum Phase / 2x', 'Minimum Phase / 4x' },
   ['FabFilter: Saturn 2'] = { 'Off / Off', 'Off / On', 'Good / Off', 'Good / On', 'Superb / Off', 'Superb / On' },
}

-- Build the ordered value choices ({label, value}) for a device's oversampling
-- dropdown from known_osig_order. Returns nil when the device has no defined order
-- (caller should fall back to its own label collection / sorting).
function core.osig_choices(norm)
   local order = core.known_osig_order[norm]
   if not order then
      return nil
   end
   local choices = {}
   for i, l in ipairs(order) do
      choices[i] = { label = l, value = i }
   end
   return choices
end

-- For devices whose oversampling is several *independent* chunk fields (e.g. Saturn 2's
-- "High Quality" mode and "Linear Phase" toggle), the signature above uses combined
-- labels ("High Quality / Linear Phase"). This table declares the independent axes so
-- the UI can present one dropdown per axis while still patching the combined label.
-- Each axis lists its own labels in ascending order; the combined signature key is
-- always axis1 .. " / " .. axis2.
core.known_osig_axes = {
   ['FabFilter: Saturn 2'] = {
      { name = 'High Quality', labels = { 'Off', 'Good', 'Superb' } },
      { name = 'Linear Phase', labels = { 'Off', 'On' } },
   },
}

function core.osig_axes(norm)
   return core.known_osig_axes[norm]
end


--------------------------------------------------------------------------------
-- The recognised primary parameter name for a device (the one we snap to and
-- drive). Works for string, list, and table style known_devices_parameters.

--------------------------------------------------------------------------------
-- The recognised primary parameter name for a device (the one we snap to and
-- drive). Works for string, list, and table style known_devices_parameters.
-- Matching is exact: only the device names hard-coded in known_devices_parameters
-- are recognised.

--------------------------------------------------------------------------------
-- Strip the host format prefix (VST/VST3/AU/DX/CLAP/LV2) from a device name so a
-- single known_devices_parameters entry matches every plugin format. Lua patterns
-- lack alternation, so the prefixes are tested explicitly. Examples:
--   "VST3: FabFilter: Pro-Q 3" -> "FabFilter: Pro-Q 3"
--   "AU: FabFilter: Pro-Q 3"   -> "FabFilter: Pro-Q 3"
--   "FabFilter: Pro-Q 3"       -> "FabFilter: Pro-Q 3" (unchanged)

function core.normalize_device_name(name)
   name = tostring(name)
   local prefixes = { "VST3:", "VST:", "AU:", "DX:", "CLAP:", "LV2:" }
   for _, p in ipairs(prefixes) do
      if name:sub(1, #p) == p then
         return name:sub(#p + 1):gsub("^%s+", "")
      end
   end
   return name
end

function core.known_primary(device_name)
    local norm = core.normalize_device_name(device_name)
    local kp = core.known_devices_parameters[norm]
    if not kp then
       return nil
    end
    -- VST3 builds expose no host oversampling parameter; a VST3 device is only supported
    -- when a state-chunk signature exists for it. Without one, do not report a known
    -- (fixed-parameter) primary, or device_selected would route it down the known path and
    -- apply_parameter_value could find neither a host parameter nor a chunk signature,
    -- leaving an inactive row Set cannot apply. Non-VST3 builds may still expose the host
    -- parameter (and are unaffected by this gate).
    if device_name:sub(1, 5) == "VST3:" and not core.known_osig[norm] then
       return nil
    end
    if type(kp) == "string" then
       return kp
    end
    if type(kp) == "table" then
       if kp.primary then
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
   local kp = core.known_devices_parameters[core.normalize_device_name(device_name)]
   if type(kp) == "table" then
      if kp.secondary then
         return kp.secondary.name
      end
      if kp[2] then
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
      ["parameter_label_id"] = "parameters_label_" .. row_number,
      ["parameter_value_popup_id"] = "parameter_value_popup_" .. row_number,
      ["parameter_value_slider_id"] = "parameter_value_slider_" .. row_number,
      ["parameter_value_secondary_popup_id"] = "parameter_value_secondary_popup_" .. row_number,
      ["parameter_value_secondary_label_id"] = "parameter_value_secondary_label_" .. row_number,
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
   return str:len() .. ";" .. str
end

function core.decode_fields(str)
    if type(str) ~= "string" then
        return {}
    end
    local fields = {}
    local i = 1
    local len = str:len()
   while i <= len do
      local sep = str:find(";", i, true)
      if not sep then
         -- A valid field is always "len;data"; a missing separator on remaining content
         -- means a trailing unframed suffix, so the record is malformed. Reject it whole
         -- rather than accepting a partial prefix that could override the valid cache.
         return {}
      end
      local field_len = tonumber(str:sub(i, sep - 1))
      -- A length that is missing, not a whole number, or negative would either drop the
      -- field's data or (for a negative length) reset the cursor to the semicolon and hang
      -- the loader. A field that runs past the end of the string is truncated. In all of
      -- these cases the cached entry is malformed, so refuse to decode it rather than risk
      -- a hang or partial data being merged.
      if field_len == nil or field_len ~= math.floor(field_len) or field_len < 0 then
         return {}
      end
      local field_end = sep + field_len
      if field_end > len then
         return {}
      end
      table.insert(fields, str:sub(sep + 1, field_end))
      i = field_end + 1
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
      if n == target then
         return i
      end
   end
   for i, n in ipairs(names) do
      if tostring(n):lower():match("^%s*(.-)%s*$") == tl then
         return i
      end
   end
   for i, n in ipairs(names) do
      if tostring(n):lower():find(tl, 1, true) then
         return i
      end
   end
   return nil
end


--------------------------------------------------------------------------------
-- True when two lists contain the same set of names, ignoring order.

function core.same_name_set(a, b)
   if #a ~= #b then return false end
   local seen = {}
   for _, v in ipairs(a) do seen[v] = true end
   for _, v in ipairs(b) do
      if not seen[v] then return false end
   end
   return true
end


--------------------------------------------------------------------------------
-- Build the device dropdown items from either the live `devices` map (when it
-- has been scanned) or the persisted `cached_device_names` list otherwise.

function core.collect_device_items(devices, cached_device_names)
   local device_items = {}
   if next(devices) ~= nil then
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
   if parameter_name then
      for p = 1, #parameter_names do
         if parameter_names[p] == parameter_name then
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
      if d < best then
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
      if idx and idx >= 1 and idx <= count and not seen[idx] then
         seen[idx] = true
         targets[#targets + 1] = idx
      end
   end

   local function add_by_name(name)
      if name then
         local i = core.match_parameter(parameter_names, name)
         if i then add(i) end
      end
   end

   add_by_name(core.known_primary(device_name))
   add_by_name(core.known_secondary(device_name))

   if selected and selected.parameter_name then
      add_by_name(selected.parameter_name)
   else
      add(selected and selected.parameter_index)
   end

   if selected and selected.secondary_parameter_name then
      add_by_name(selected.secondary_parameter_name)
   else
      add(selected and selected.secondary_parameter_index)
   end

   return targets
end


--------------------------------------------------------------------------------
-- Oversampling via VST3 state-chunk patching (multi-state).
--
-- Some FabFilter VST3 builds do not expose their oversampling setting as a host
-- parameter, so it cannot be driven through device:parameter(). However the full
-- plugin state (including oversampling) is available as the raw
-- 'active_preset_data' blob, and re-importing a modified blob changes the
-- setting. For each oversampling value the user can select in the plugin's own
-- GUI we capture the blob, then learn which bytes encode that value; at runtime
-- we set those exact bytes to the chosen value. This generalises the old binary
-- off/on toggle to any number of discrete values (Off / 2x / 4x / …).
--
-- An entry is { pos = 1-based byte index, values = { [label] = byte value } }.
-- The dropdown labels themselves come from a sibling device that DOES expose the
-- parameter (typically the VST2 build); the bytes are always captured from the
-- VST3 device, because VST2 and VST3 preset chunks are not interchangeable.

-- Learn the byte positions that differ between any two captured blobs, recording
-- each label's byte value at those positions. `blobs` and `labels` are parallel
-- arrays (labels[k] is the label for blobs[k]). Returns the entries table.
function core.diff_blobs_multi(blobs, labels)
   local entries = {}
   if not blobs or #blobs < 2 or #blobs ~= #labels then
      return entries
   end
   local n = blobs[1]:len()
   for k = 2, #blobs do
      local m = blobs[k]:len()
      if m < n then
         n = m
      end
   end
   for i = 1, n do
      local first = blobs[1]:byte(i)
      local vary = false
      for k = 2, #blobs do
         if blobs[k]:byte(i) ~= first then
            vary = true
            break
         end
      end
      if vary then
         local values = {}
         for k = 1, #blobs do
            values[labels[k]] = blobs[k]:byte(i)
         end
         entries[#entries + 1] = { pos = i, values = values }
      end
   end
   return entries
end

-- Return a new blob with every learned position set to the byte recorded for
-- `target` (a label string). Positions whose `target` value is unknown, or that
-- lie outside the current blob, are left untouched.
function core.patch_blob(blob, entries, target)
   if not blob or not entries or #entries == 0 then
      return blob
   end
   local n = blob:len()
   -- Collect only the (position, byte) pairs that actually change, keyed by position.
   local patches = {}
   for _, e in ipairs(entries) do
      local b = e.values[target]
      if b ~= nil and e.pos >= 1 and e.pos <= n then
         patches[e.pos] = b
      end
   end
   -- Nothing to change: return the original blob without copying it byte-by-byte.
   if not next(patches) then
      return blob
   end
   -- Splice the original blob around the changed offsets instead of rebuilding it,
   -- keeping this O(changes) rather than O(blob size) for large VST3 chunks.
   local positions = {}
   for pos in pairs(patches) do positions[#positions + 1] = pos end
   table.sort(positions)
   local out = {}
   local prev = 0
   for _, pos in ipairs(positions) do
      if pos > prev + 1 then
         out[#out + 1] = blob:sub(prev + 1, pos - 1)
      end
      out[#out + 1] = string.char(patches[pos])
      prev = pos
   end
   if prev < n then
      out[#out + 1] = blob:sub(prev + 1, n)
   end
   return table.concat(out)
end

-- Best-matching label for the current blob: the label whose recorded bytes match
-- the most learned positions. Returns nil when nothing matches (or no entries).
function core.detect_label(blob, entries)
   if not blob or not entries or #entries == 0 then
      return nil
   end
   local n = blob:len()
   -- Collect the distinct labels in a sorted list so ties are broken deterministically
   -- (hash iteration order is undefined in Lua 5.1/JIT and would otherwise make the
   -- chosen label vary between runs, destabilising UI display and toggle behaviour).
   local label_set = {}
   local label_list = {}
   for _, e in ipairs(entries) do
      for lab in pairs(e.values) do
         if not label_set[lab] then
            label_set[lab] = true
            label_list[#label_list + 1] = lab
         end
      end
   end
   table.sort(label_list)
   local best, best_defined = nil, 0
   for _, lab in ipairs(label_list) do
      local score = 0
      local defined = 0
      for _, e in ipairs(entries) do
         local b = e.values[lab]
         if b ~= nil then
            defined = defined + 1
            if e.pos >= 1 and e.pos <= n and blob:byte(e.pos) == b then
               score = score + 1
            end
         end
      end
      -- Fail closed: only report a match when the label is defined for every learned
      -- position AND each aligns. A structurally incomplete cached signature (a label
      -- missing at some position) would otherwise match on its single present byte and
      -- patch_blob would apply a target using only that subset of offsets, defeating the
      -- fail-closed protection. Ties are broken deterministically by the sorted label order.
      if defined == #entries and score == defined and defined > best_defined then
         best_defined = defined
         best = lab
      end
   end
   return best
end

-- Minimal base64 codec (arithmetic only, no bit ops) for VST3 preset chunks.
local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_val(c)
   if c == nil then return -1 end
   if c >= 65 and c <= 90 then return c - 65 end
   if c >= 97 and c <= 122 then return c - 71 end
   if c >= 48 and c <= 57 then return c + 4 end
   if c == 43 then return 62 end
   if c == 47 then return 63 end
   return -1
end

function core.b64decode(s)
   if type(s) ~= "string" then return nil end
   s = s:gsub("%s+", "")
   local n = s:len()
   -- A valid base64 string is a multiple of four characters. Anything else (stray
   -- characters, wrong length) is not a VST3 chunk, so reject it rather than silently
   -- mapping bad characters to zero and producing a blob detect_label_xml could accept.
   if n % 4 ~= 0 then return nil end
   if n == 0 then return "" end
   local out = {}
   local i = 1
   while i <= n do
      local acc = 0
      local pads = 0
      for k = 0, 3 do
         local ch = s:sub(i + k, i + k)
         if ch == "=" then
            -- Padding still occupies its 6-bit slot (value 0); only the output bytes are
            -- suppressed, so the accumulator must still shift.
            pads = pads + 1
            acc = acc * 64
         elseif pads > 0 then
            -- Padding must be contiguous at the end of the quartet.
            return nil
         else
            local cv = b64_val(ch:byte())
            if cv < 0 then return nil end
            acc = acc * 64 + cv
         end
      end
      -- Padding is only legal in the final quartet, and at most two "=" signs.
      if pads > 0 and i + 3 < n then return nil end
      if pads > 2 then return nil end
      out[#out + 1] = string.char(math.floor(acc / 65536) % 256)
      if pads < 2 then out[#out + 1] = string.char(math.floor(acc / 256) % 256) end
      if pads < 1 then out[#out + 1] = string.char(acc % 256) end
      i = i + 4
   end
   return table.concat(out)
end

function core.b64encode(s)
   local out = {}
   local i = 1
   local n = s:len()
   while i <= n do
      local b1 = s:byte(i); i = i + 1
      local b2 = (i <= n) and s:byte(i) or 0; i = i + 1
      local b3 = (i <= n) and s:byte(i) or 0; i = i + 1
      local v = b1 * 65536 + b2 * 256 + b3
      out[#out + 1] = B64_ALPHABET:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
      out[#out + 1] = B64_ALPHABET:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
      out[#out + 1] = B64_ALPHABET:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1)
      out[#out + 1] = B64_ALPHABET:sub(v % 64 + 1, v % 64 + 1)
   end
   local rem = n % 3
   if rem == 1 then out[#out] = "="; out[#out - 1] = "=" end
   if rem == 2 then out[#out] = "=" end
   return table.concat(out)
end

-- VST3 hosts (Renoise included) store plugin state as XML where the opaque
-- binary chunk lives base64-encoded inside <ParameterChunk><![CDATA[…]]></ParameterChunk>.
-- Patchers must operate on the *decoded* chunk, then re-encode, so the preset
-- stays valid XML. These helpers do exactly that.

function core.patch_osig_xml(xml, entries, target)
   local b64 = xml:match("<ParameterChunk><!%[CDATA%[([%s%S]-)%]%]></ParameterChunk>")
   if not b64 then return nil end
   local bin = core.b64decode(b64)
   if not bin or bin:len() == 0 then return nil end
   local newbin = core.patch_blob(bin, entries, target)
   if not newbin or newbin == bin then return nil end
   local newb64 = core.b64encode(newbin)
   return (xml:gsub("<ParameterChunk><!%[CDATA%[[%s%S]-%]%]></ParameterChunk>",
      "<ParameterChunk><![CDATA[" .. newb64 .. "]]></ParameterChunk>", 1))
end

function core.detect_label_xml(xml, entries)
   local b64 = xml:match("<ParameterChunk><!%[CDATA%[([%s%S]-)%]%]></ParameterChunk>")
   if not b64 then return nil end
   local bin = core.b64decode(b64)
   if not bin or bin:len() == 0 then return nil end
   return core.detect_label(bin, entries)
end

-- The first label found in `entries`, used as a sensible default target.
function core.first_label(entries)
   if not entries or #entries == 0 then
      return nil
   end
   return next(entries[1].values) or nil
end

-- Serialize a multi-state entries table into a single printable string. Each
-- entry becomes one length-prefixed field holding "pos\0label\0byte\0label\0byte…".
function core.encode_osig(entries)
   local out = ""
   for _, e in ipairs(entries) do
      local labels = {}
      for lab in pairs(e.values) do
         labels[#labels + 1] = lab
      end
      table.sort(labels)
      local parts = { tostring(e.pos) }
      for _, lab in ipairs(labels) do
         parts[#parts + 1] = lab
         parts[#parts + 1] = tostring(e.values[lab])
      end
      -- The inner "pos\0label\0byte…" record holds literal NUL separators, which are not
      -- valid XML characters; the encoded signature is serialized into Renoise
      -- ObservableStringList values (preferences/song XML), so a raw NUL would corrupt the
      -- cache. Base64-encode the inner record before length-prefixing it: base64 is fully
      -- printable and XML-safe, and decode_osig reverses it.
      out = out .. core.encode_field(core.b64encode(table.concat(parts, "\0")))
   end
   return out
end

-- Inverse of encode_osig.
function core.decode_osig(str)
   local entries = {}
   if not str or str == "" then
      return entries
   end
    local fields = core.decode_fields(str)
    local malformed = false
    local seen_pos = {}
    for _, f in ipairs(fields) do
       -- The inner record is base64 (XML-safe); a field that is not valid base64 is malformed.
       local inner = core.b64decode(f)
       local accepted = false
       if inner then
          local parts = {}
          for p in inner:gmatch("[^%z]+") do
             parts[#parts + 1] = p
          end
          if #parts >= 3 and (#parts % 2) == 1 then
             local pos = tonumber(parts[1])
             local values = {}
             local ok = true
             -- Positions must be positive integers; a non-integer would break the byte
             -- offset math in patch_blob. Bytes must be integers in 0..255 so they pass
             -- cleanly to string.char (a malformed cached entry like byte 999 would otherwise
             -- raise mid-Set instead of being ignored).
             if not pos or pos ~= math.floor(pos) or pos < 1 then
                ok = false
             end
             local seen_label = {}
             for i = 2, #parts, 2 do
                local lab = parts[i]
                local byte = tonumber(parts[i + 1])
                if byte == nil or byte ~= math.floor(byte) or byte < 0 or byte > 255 then
                   ok = false
                   break
                end
                -- A label repeated within one entry is a contradictory record; reject it rather
                -- than letting the last value silently win.
                if seen_label[lab] then
                   ok = false
                   break
                end
                seen_label[lab] = true
                values[lab] = byte
             end
             if ok then
                -- patch_blob collapses duplicate positions with patches[e.pos] = b, so two
                -- entries for the same offset that disagree would let Set write a byte
                -- combination matching no learned label. Reject any repeated position: leave
                -- accepted false so the whole signature is rejected below.
                if not seen_pos[pos] then
                   seen_pos[pos] = true
                   entries[#entries + 1] = { pos = pos, values = values }
                   accepted = true
                end
             end
          end
       end
       -- A single malformed field poisons the whole signature: discarding it and keeping the
       -- surviving offsets would let detect_label/patch_blob still match and rewrite at those
       -- offsets, producing a hybrid chunk instead of failing closed. Reject the entire record.
       if not accepted then
          malformed = true
       end
    end
    if malformed then
       return {}
   end
    -- Fail closed on incomplete label coverage: every learned position must declare the
    -- same set of labels. A cached signature whose entries disagree (a label present at one
    -- offset but missing at another) is malformed; detect_label could still match the present
    -- bytes for the current state while patch_blob silently skips the missing positions for
    -- the requested target, producing a hybrid chunk that rewrites part of an unrelated state.
    -- Reject such signatures entirely rather than storing a partial one in osig.
    if #entries >= 2 then
       local ref = {}
       for lab in pairs(entries[1].values) do ref[lab] = true end
       local ref_count = 0
       for _ in pairs(ref) do ref_count = ref_count + 1 end
       for i = 2, #entries do
          local count = 0
          local consistent = true
          for lab in pairs(entries[i].values) do
             count = count + 1
             if not ref[lab] then consistent = false end
          end
          if not consistent or count ~= ref_count then
             return {}
          end
       end
    end
    return entries
end


return core
