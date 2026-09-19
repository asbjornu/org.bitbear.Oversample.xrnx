-- Run from the tool root: lua test/oversample_ui_test.lua (requires luaunit).
-- Models visible-child sizing and property changes, not native Renoise rendering.
package.path = "./?.lua;" .. package.path
local lu = require("luaunit")
local core = require("Oversample/oversample_core")

local function upvalue(fn, wanted)
    local i = 1
    while true do
        local name, value = debug.getupvalue(fn, i)
        if not name then error("Missing upvalue: " .. wanted) end
        if name == wanted then return value end
        i = i + 1
    end
end

TestDialogLayout = {}

function TestDialogLayout:setUp()
    local test = self
    self.watch = nil
    self.builder = { views = {} }
    self.spacing = 4
    self.control_height = 20

    local function extent(view, axis)
        local state = view._state
        local count, sum, maximum = 0, 0, 0
        for _, child in ipairs(state.views) do
            if child.visible then
                local size = extent(child, axis)
                count, sum, maximum = count + 1, sum + size, math.max(maximum, size)
            end
        end
        local horizontal = state.kind == "row" or state.kind == "horizontal_aligner"
        local natural = axis == "height" and test.control_height or 0
        if horizontal or state.kind == "column" then
            natural = ((axis == "width") == horizontal) and
                (sum + math.max(count - 1, 0) * (state.spacing or 0)) or maximum
            natural = natural + 2 * (state.margin or 0)
        end
        return math.max(state[axis] or 0, natural)
    end

    for _, kind in ipairs({"row", "column", "horizontal_aligner", "text",
        "multiline_text", "popup", "slider", "button", "space"}) do
        self.builder[kind] = function(_, spec)
            local state = {kind = kind, views = {}, visible = true}
            for key, value in pairs(spec) do
                if type(key) == "number" then state.views[key] = value
                else state[key] = value end
            end
            function state.add_child(rack, child)
                rack.views[#rack.views + 1] = child
            end
            function state.remove_child(rack, child)
                for i, candidate in ipairs(rack.views) do
                    if candidate == child then table.remove(rack.views, i); return end
                end
                error("Child not found")
            end
            local view = setmetatable({_state = state}, {
                __index = function(object, key)
                    if key == "width" or key == "height" then return extent(object, key) end
                    return state[key]
                end,
                __newindex = function(_, key, value)
                    state[key] = value
                    -- Renoise single-line text grows on assignment, but never shrinks.
                    if key == "text" and kind == "text" then
                        state.width = math.max(state.width or 0, #value * test.control_height * 0.3)
                    end
                    if test.watch then test.watch() end
                end
            })
            if spec.id then
                lu.assertIsNil(test.builder.views[spec.id], "Duplicate view ID")
                test.builder.views[spec.id] = view
            end
            return view
        end
    end

    renoise = {
        ViewBuilder = setmetatable({DEFAULT_DIALOG_MARGIN = 8,
            DEFAULT_CONTROL_SPACING = self.spacing, DEFAULT_CONTROL_MARGIN = 4,
            DEFAULT_CONTROL_HEIGHT = self.control_height}, {
            __call = function() return test.builder end
        }),
        Document = {
            create = function() return function(spec) return spec end end,
            ObservableStringList = function() return {} end
        },
        song = function() return {tracks = {}} end,
        app = function() return {
            show_custom_dialog = function(_, _, view)
                test.root = view
                return {visible = true, close = function() end}
            end
        } end
    }
    -- Background scans stay pending; each test supplies only the device state it needs.
    ProcessSlicer = function() return {start = function() end} end
    dofile("Oversample/Oversample.lua")
    oversample()
    self.views = self.builder.views
    self.row = create_settings_row()
    self.views.settings_container:add_child(self.row)
    self.ids = core.create_settings_row_identifiers(1)
    self.popup = self.views[self.ids.parameter_value_popup_id]
    self.slider = self.views[self.ids.parameter_value_slider_id]
    self.secondary = self.views[self.ids.parameter_value_secondary_popup_id]
    self.secondary_label = self.views[self.ids.parameter_value_secondary_label_id]
    self.footer = self.root.views[1].views[4]
    self.selected = upvalue(update_secondary, "selected_devices")
end

function TestDialogLayout:tearDown()
    self.watch = nil
    destroy()
end

function TestDialogLayout:test_footer_matches_populated_row()
    self.views[self.ids.parameter_popup_id].visible = false
    self.views[self.ids.parameter_label_id].text = "Oversampling:"
    self.views[self.ids.parameter_label_id].visible = true
    self.slider.visible = false
    self.popup.visible = true
    lu.assertEquals(self.footer.width, self.row.width)
    lu.assertTrue(self.views.status.width + self.footer.views[2].width <= self.footer.width)
    lu.assertEquals(self.root.width, self.row.width + 2 * self.root.margin)
    lu.assertEquals(self.row.views[#self.row.views], self.views[self.ids.add_button_id])
end

function TestDialogLayout:test_status_does_not_expand_dialog()
    local status = self.views.status
    local width, height = status.width, status.height
    local dialog_width, dialog_height = self.root.width, self.root.height
    for _, text in ipairs({string.rep("Long progress message ", 100), "Done."}) do
        status.text = text
        lu.assertEquals({status.width, status.height}, {width, height})
        lu.assertEquals({self.root.width, self.root.height}, {dialog_width, dialog_height})
    end
end

function TestDialogLayout:test_unused_secondary_is_hidden_without_collapsing_column()
    local width = self.row.width
    lu.assertFalse(self.secondary.visible)
    lu.assertFalse(self.secondary_label.visible)
    for _, osig_driven in ipairs({false, true}) do
        self.secondary.visible = true
        self.secondary_label.visible = true
        self.selected[1] = {parameter_name = "Oversampling", osig_driven = osig_driven}
        update_secondary(1, "VST3: FabFilter: Pro-C 2", {})
        lu.assertFalse(self.secondary.visible)
        lu.assertFalse(self.secondary_label.visible)
        lu.assertFalse(self.secondary.active)
        lu.assertEquals(self.row.width, width)
    end
end

function TestDialogLayout:test_saturn_secondary_remains_available_when_primary_is_off()
    local width = self.row.width
    local axes = core.osig_axes("FabFilter: Saturn 2")
    self.selected[1] = {osig_driven = true, osig_multi_axis = true,
        osig_axes = axes, osig_axis2_label = "On", osig_target_label = "Off / On"}
    update_secondary(1, "VST3: FabFilter: Saturn 2", {{}})
    lu.assertTrue(self.secondary.visible)
    lu.assertTrue(self.secondary.active)
    lu.assertTrue(self.secondary_label.visible)
    lu.assertEquals(self.secondary_label.text, "Linear Phase:")
    lu.assertEquals(self.secondary.items, {"Off", "On"})
    lu.assertEquals(self.secondary.value, 2)
    lu.assertEquals(self.row.width, width)
end

function TestDialogLayout:test_osig_secondary_shows_for_combined_linear_phase_label()
    -- A VST3 Pro-Q 3 oversampling mode like "Linear Phase / Medium" is a combined
    -- label; the dependent "Processing Resolution" secondary must still appear
    -- (regression: the old check compared the whole combined label and never matched).
    local function make_param(name, labels)
        local p = { name = name, value_min = 0, value_max = #labels - 1, value_quantum = 1, value = 0 }
        setmetatable(p, {
            __newindex = function(t, k, v) rawset(t, k, v) end,
            __index = function(t, k)
                if (k == "value_string") then return labels[(t.value or 0) + 1] or "" end
                return rawget(t, k)
            end
        })
        return p
    end
    local sibling = {
        parameter = function(_, p)
            if (p == 1) then return make_param("Oversampling", { "Off", "2x", "4x" }) end
            if (p == 2) then return make_param("Processing Resolution", { "Low", "Medium", "High" }) end
            error("no such parameter")
        end
    }
    self.selected[1] = {
        osig_driven = true,
        parameter_name = "Processing Mode",
        osig_target_label = "Linear Phase / Medium",
        sibling_device = sibling,
    }
    update_secondary(1, "VST3: FabFilter: Pro-Q 3", {})
    lu.assertTrue(self.secondary.visible)
    lu.assertEquals(self.secondary.items, { "Low", "Medium", "High" })
    lu.assertEquals(self.secondary_label.text, "Processing Resolution:")
end

function TestDialogLayout:test_primary_switches_never_temporarily_expand_row()
    local width = self.row.width
    self.watch = function()
        lu.assertFalse(self.popup.visible and self.slider.visible, "Transient control overlap")
        lu.assertTrue(self.row.width <= width, "Transient row expansion")
    end
    local apply = upvalue(upvalue(parameter_selected, "set_value_control"), "apply_value_to_control")
    local cache = upvalue(upvalue(apply, "parameter_choices"), "parameter_choices_cache")
    local parameter = {name = "Oversampling", value_min = 0, value_max = 1,
        value_quantum = 0, value = 0}
    local device = {parameter = function() return parameter end}
    local key = "Oversampling\0" .. "0\0" .. "1\0q0"
    self.selected[1] = {}
    for _, choices in ipairs({{{value = 0, label = "Off"}, {value = 1, label = "On"}}, {}}) do
        cache[key] = choices
        apply(1, "VST: FabFilter: Pro-C 2", {device}, 1, 0)
        lu.assertEquals(self.popup.visible, #choices > 0)
        lu.assertEquals(self.slider.visible, #choices == 0)
        lu.assertEquals(self.row.width, width)
    end
    local show_osig = upvalue(upvalue(device_selected, "apply_parameter_value"), "show_osig_dropdown")
    show_osig(1, "VST3: FabFilter: Pro-C 2", {{}}, {{value = 1, label = "Off"}}, "Oversampling")
    lu.assertTrue(self.popup.visible)
    lu.assertFalse(self.slider.visible)
    lu.assertEquals(self.row.width, width)
end

function TestDialogLayout:test_osig_set_patches_vst3_binary_chunk()
   -- Drive the "Set" path for a VST3 device whose oversampling is chunk-driven
   -- (no host parameter). The learned bytes must be written into active_preset_data.
   local apply = upvalue(set_values, "apply_osig_to_device_name")
   local osig = upvalue(apply, "osig")
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local norm = "FabFilter: Pro-C 2"
   local off = string.char(0, 1, 2, 3, 4)
   local two = string.char(0, 1, 9, 3, 9)
   osig[norm] = core.diff_blobs_multi({ off, two }, { "Off", "2x" })
   local device_name = "VST3: FabFilter: Pro-C 2"
   local device = { active_preset_data = off }
   devices[device_name] = { instances = { device } }
   self.selected[1] = { device_name = device_name, osig_driven = true, osig_target_label = "2x" }
   renoise.song = function() return { tracks = {}, file_name = "" } end
   set_values()
   lu.assertEquals(device.active_preset_data, two)
end

function TestDialogLayout:test_osig_set_patches_vst3_xml_chunk()
   -- VST3 hosts wrap the chunk in base64 inside <ParameterChunk><![CDATA[…]]></ParameterChunk>;
   -- the Set path must decode, patch, and re-encode the binary, not corrupt the XML.
   local apply = upvalue(set_values, "apply_osig_to_device_name")
   local osig = upvalue(apply, "osig")
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local norm = "FabFilter: Pro-C 2"
   local off = string.char(0, 1, 2, 3, 4)
   local two = string.char(0, 1, 9, 3, 9)
   osig[norm] = core.diff_blobs_multi({ off, two }, { "Off", "2x" })
   local xml = "<ParameterChunk><![CDATA[" .. core.b64encode(off) .. "]]></ParameterChunk>"
   local device_name = "VST3: FabFilter: Pro-C 2"
   local device = { active_preset_data = xml }
   devices[device_name] = { instances = { device } }
   self.selected[1] = { device_name = device_name, osig_driven = true, osig_target_label = "2x" }
   renoise.song = function() return { tracks = {}, file_name = "" } end
   set_values()
   lu.assertStrContains(device.active_preset_data, "<ParameterChunk><![CDATA[")
   lu.assertEquals(core.b64decode(string.match(device.active_preset_data, "CDATA%[([%s%S]-)%]%]")), two)
end

function TestDialogLayout:test_osig_set_without_target_toggles_to_next_label()
   -- A row with no explicit target uses the cyclic "toggle": detect current state
   -- ("Off") and step to the next label in sorted order ("2x").
   local apply = upvalue(set_values, "apply_osig_to_device_name")
   local osig = upvalue(apply, "osig")
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local norm = "FabFilter: Pro-C 2"
   local off = string.char(0, 1, 2, 3, 4)
   local two = string.char(0, 1, 9, 3, 9)
   osig[norm] = core.diff_blobs_multi({ off, two }, { "Off", "2x" })
   local device_name = "VST3: FabFilter: Pro-C 2"
   local device = { active_preset_data = off }
   devices[device_name] = { instances = { device } }
   self.selected[1] = { device_name = device_name, osig_driven = true }
   renoise.song = function() return { tracks = {}, file_name = "" } end
   set_values()
   lu.assertEquals(device.active_preset_data, two)
end

function TestDialogLayout:test_osig_set_skips_non_vst3_device()
   -- The chunk-signature path is VST3-only; a VST2 build must be left untouched.
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local off = string.char(0, 1, 2, 3, 4)
   local device_name = "VST: FabFilter: Pro-C 2"
   local device = { active_preset_data = off }
   devices[device_name] = { instances = { device } }
   self.selected[1] = { device_name = device_name, osig_driven = true, osig_target_label = "2x" }
   renoise.song = function() return { tracks = {}, file_name = "" } end
   set_values()
   lu.assertEquals(device.active_preset_data, off)
end

function TestDialogLayout:test_osig_target_for_row_combines_secondary_safely()
   -- A combined primary label must have its trailing portion replaced by the dependent
   -- secondary, never appended as a third segment (which would match no signature label).
   local target_for_row = upvalue(set_values, "osig_target_for_row")
   self.selected[1] = { osig_driven = true, osig_target_label = "Linear Phase / Medium",
      osig_target_label_sec = "High" }
   lu.assertEquals(target_for_row(1), "Linear Phase / High")
   -- A simple primary has the secondary appended as a fresh segment.
   self.selected[1] = { osig_driven = true, osig_target_label = "2x", osig_target_label_sec = "On" }
   lu.assertEquals(target_for_row(1), "2x / On")
   -- No secondary: just the primary.
   self.selected[1] = { osig_driven = true, osig_target_label = "Off" }
   lu.assertEquals(target_for_row(1), "Off")
   -- A nil primary is guarded (no crash) and yields the secondary alone.
   self.selected[1] = { osig_driven = true, osig_target_label_sec = "On" }
   lu.assertEquals(target_for_row(1), "On")
   -- Non-osig rows return nil.
   self.selected[1] = { osig_driven = false }
   lu.assertIsNil(target_for_row(1))
end

function TestDialogLayout:test_osig_set_toggle_uses_natural_order()
   -- Pro-L 2 natural order is Off, 2x, 4x, 8x, 16x, 32x. Alphabetical sorting would step
   -- Off -> 16x (wrong); the natural order must step Off -> 2x.
   local apply = upvalue(set_values, "apply_osig_to_device_name")
   local osig = upvalue(apply, "osig")
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local norm = "FabFilter: Pro-L 2"
   local blobs, labels = {}, { "Off", "2x", "4x", "8x", "16x", "32x" }
   for i = 1, #labels do blobs[i] = string.char(0, i, 0, 0, 0) end
   osig[norm] = core.diff_blobs_multi(blobs, labels)
   local device_name = "VST3: FabFilter: Pro-L 2"
   local device = { active_preset_data = blobs[1] }
   devices[device_name] = { instances = { device } }
   self.selected[1] = { device_name = device_name, osig_driven = true }
   renoise.song = function() return { tracks = {}, file_name = "" } end
   set_values()
   lu.assertEquals(device.active_preset_data, blobs[2])
end

function TestDialogLayout:test_apply_parameter_value_clears_stale_multi_axis_state()
   -- Switching from a multi-axis device (Saturn 2) to a single-axis one (Pro-Q 3) must
   -- clear the stale osig_multi_axis / osig_axes state, or single-axis labels would be
   -- treated as combined "axis1 / axis2" keys.
   local app = upvalue(device_selected, "apply_parameter_value")
   local osig = upvalue(app, "osig")
   local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
   local sig = { { pos = 1, values = { ["Off"] = 0, ["2x"] = 1 } } }
   osig["FabFilter: Saturn 2"] = sig
   osig["FabFilter: Pro-Q 3"] = sig
   self.selected[1] = {}
   devices["VST3: FabFilter: Saturn 2"] = { instances = { { active_preset_data = "" } } }
   app(1, "VST3: FabFilter: Saturn 2", "Oversampling")
   lu.assertTrue(self.selected[1]["osig_multi_axis"])
   lu.assertNotEquals(self.selected[1]["osig_axes"], nil)
   devices["VST3: FabFilter: Pro-Q 3"] = { instances = { { active_preset_data = "" } } }
   app(1, "VST3: FabFilter: Pro-Q 3", "Oversampling")
   lu.assertIsNil(self.selected[1]["osig_multi_axis"])
   lu.assertIsNil(self.selected[1]["osig_axes"])
end

function TestDialogLayout:test_update_secondary_osig_multi_axis_clears_stale_secondary()
   -- A multi-axis device's secondary popup shows the next axis' labels; any dependent
   -- (sibling) secondary state left by a previous device must be cleared so the combined
   -- target is never corrupted (e.g. "Off / On / Medium").
   local upd = upvalue(update_secondary, "update_secondary_osig")
   local axes = core.osig_axes("FabFilter: Saturn 2")
   self.selected[1] = {
      osig_driven = true,
      osig_multi_axis = true,
      osig_axes = axes,
      osig_axis2_label = "On",
      osig_target_label = "Off / On",
      osig_target_label_sec = "Medium",
      secondary_parameter_index = 5,
      secondary_parameter_value = "Hi",
      secondary_parameter_name = "Processing Resolution",
      secondary_parameter_choices = { { label = "X", value = 1 } },
   }
   upd(1, "VST3: FabFilter: Saturn 2", { { active_preset_data = "" } })
   lu.assertIsNil(self.selected[1]["osig_target_label_sec"])
   lu.assertIsNil(self.selected[1]["secondary_parameter_choices"])
   lu.assertIsNil(self.selected[1]["secondary_parameter_index"])
   lu.assertIsNil(self.selected[1]["secondary_parameter_name"])
    lu.assertIsNil(self.selected[1]["secondary_parameter_value"])
    lu.assertEquals(self.secondary.items, axes[2].labels)
 end


function TestDialogLayout:test_apply_osig_to_device_name_is_fail_closed_on_unrecognized_state()
    -- When the device's current VST3 chunk matches no learned byte, Set must leave the
    -- chunk untouched (fail closed) rather than overwriting it with a guessed patch.
    local apply = upvalue(set_values, "apply_osig_to_device_name")
    local osig = upvalue(apply, "osig")
    local devices = upvalue(upvalue(set_values, "ensure_device_instances"), "devices")
    local norm = "FabFilter: Pro-C 2"
    local off = string.char(0, 1, 2, 3, 4)
    local two = string.char(0, 1, 9, 3, 9)
    osig[norm] = core.diff_blobs_multi({ off, two }, { "Off", "2x" })
    local unknown = string.char(0, 1, 7, 3, 7)
    local device_name = "VST3: FabFilter: Pro-C 2"
    local device = { active_preset_data = unknown }
    devices[device_name] = { instances = { device } }
    self.selected[1] = { device_name = device_name, osig_driven = true, osig_target_label = "2x" }
    renoise.song = function() return { tracks = {}, file_name = "" } end
    set_values()
    lu.assertEquals(device.active_preset_data, unknown)
end

function TestDialogLayout:test_update_secondary_osig_seeds_secondary_from_combined_label()
    -- For a device whose primary axis is already a combined label (e.g. Pro-Q 3's
    -- "Linear Phase / Maximum"), the resolution implied by the suffix ("Maximum") must seed
    -- osig_target_label_sec, so Minimize/Maximize land on the right resolution instead of
    -- always defaulting to the first choice ("Low").
    local upd = upvalue(update_secondary, "update_secondary_osig")
    local labels = { "Low", "Medium", "High", "Very High", "Maximum" }
    local make_param = function()
        local p = { name = "Processing Resolution", value_min = 0, value_max = 1, value_quantum = 0.25, _v = 0 }
        return setmetatable(p, {
            __newindex = function(t, k, v)
                if (k == "value") then
                    rawset(t, "_v", v)
                    rawset(t, "value_string", labels[math.floor(v * 4 + 0.5) + 1] or "?")
                else
                    rawset(t, k, v)
                end
            end,
            __index = function(t, k)
                if (k == "value") then return rawget(t, "_v") end
                return rawget(t, k)
            end,
        })
    end
    local sibling = { parameter = function(_, p) if (p == 1) then return make_param() end error("no such parameter") end }
    self.selected[1] = {
        osig_driven = true,
        parameter_name = "Processing Mode",
        osig_target_label = "Linear Phase / Maximum",
        sibling_device = sibling,
    }
    -- parameter_choices caches by (name, range); clear any entry left by an earlier test so
    -- the sibling is actually probed (otherwise a stale 3-choice cache would be reused).
    local cache = upvalue(upvalue(upd, "parameter_choices"), "parameter_choices_cache")
    for k in pairs(cache) do cache[k] = nil end
    upd(1, "VST3: FabFilter: Pro-Q 3", { { active_preset_data = "" } })
    lu.assertEquals(self.selected[1]["osig_target_label_sec"], "Maximum")
 end

function TestDialogLayout:test_merge_osig_list_normalizes_cached_name()
   -- Older caches may persist signatures under a raw, host-prefixed name
   -- (e.g. "VST3: FabFilter: ..."); merge must normalize the key so lookups via
   -- osig[core.normalize_device_name(...)] can still find them.
   local merge = upvalue(load_tool_cache, "merge_osig_list")
   local osig = upvalue(merge, "osig")
   local raw = "VST3: Acme: Compressor"
   local list = {
      size = 1,
      [1] = core.encode_field(raw) .. core.encode_field(core.encode_osig({ { pos = 1, values = { ["Good"] = 9 } } })),
   }
   merge(list)
   lu.assertNotEquals(osig["Acme: Compressor"], nil)
   lu.assertEquals(osig[raw], nil)
end

function TestDialogLayout:test_only_newest_row_has_add_button()
    local width = self.row.width
    local previous = self.row
    for row_number = 2, 3 do
        local old_ids = core.create_settings_row_identifiers(row_number - 1)
        local row = create_settings_row()
        self.views.settings_container:add_child(row)
        for _, child in ipairs(previous.views) do
            lu.assertNotEquals(child, self.views[old_ids.add_button_id])
        end
        local ids = core.create_settings_row_identifiers(row_number)
        lu.assertEquals(row.views[#row.views], self.views[ids.add_button_id])
        lu.assertEquals(row.width, width)
        lu.assertEquals(self.footer.width, width)
        previous = row
    end
end

os.exit(lu.LuaUnit.run())
