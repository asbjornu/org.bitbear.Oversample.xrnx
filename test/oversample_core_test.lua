--[[============================================================================
test/oversample_core_test.lua

Unit tests for the pure, Renoise-independent logic in
Oversample/oversample_core.lua. Run with any Lua interpreter:

    lua test/oversample_core_test.lua

Requires the luaunit module (installed via luarocks: `luarocks install luaunit`),
so the test suite has no vendored dependency.
============================================================================]]--

local function script_dir()
   local source = debug.getinfo(1, "S").source:sub(2)
   return source:match("(.*/)") or "./"
end

local test_dir = script_dir()
local project_root = test_dir:gsub("test/", "")

package.path = project_root .. "?.lua;" ..
               test_dir .. "?.lua;" ..
               package.path

local lu = require("luaunit")
local core = require("Oversample/oversample_core")


--------------------------------------------------------------------------------
-- create_settings_row_identifiers

TestSettingsRowIdentifiers = {}

function TestSettingsRowIdentifiers:test_contains_row_number_and_suffixes()
   local ids = core.create_settings_row_identifiers(3)

   lu.assertEquals(ids["device_popup_id"], "devices_popup_3")
   lu.assertEquals(ids["parameter_popup_id"], "parameters_popup_3")
   lu.assertEquals(ids["parameter_value_popup_id"], "parameter_value_popup_3")
   lu.assertEquals(ids["parameter_value_slider_id"], "parameter_value_slider_3")
   lu.assertEquals(ids["parameter_value_secondary_popup_id"], "parameter_value_secondary_popup_3")
   lu.assertEquals(ids["settings_row_id"], "settings_row_3")
   lu.assertEquals(ids["add_button_id"], "add_button_3")
end

function TestSettingsRowIdentifiers:test_different_rows_are_distinct()
   local a = core.create_settings_row_identifiers(1)
   local b = core.create_settings_row_identifiers(2)
   lu.assertNotEquals(a["settings_row_id"], b["settings_row_id"])
end


--------------------------------------------------------------------------------
-- encode_field / decode_fields (cache serialization)
--
-- The length prefix must survive names that themselves contain ';'.

TestCacheEncoding = {}

function TestCacheEncoding:test_encode_single_field()
   lu.assertEquals(core.encode_field("abc"), "3;abc")
   lu.assertEquals(core.encode_field(""), "0;")
end

function TestCacheEncoding:test_decode_single_field()
   lu.assertEquals(core.decode_fields("3;abc"), { "abc" })
   lu.assertEquals(core.decode_fields("0;"), { "" })
end

function TestCacheEncoding:test_round_trip_single_field()
   local original = "High Quality Mode"
   lu.assertEquals(core.decode_fields(core.encode_field(original)), { original })
end

function TestCacheEncoding:test_round_trip_with_semicolon_in_name()
   -- A name that contains the delimiter must not corrupt the decode.
   local original = "Mix;Trim (2)"
   lu.assertEquals(core.decode_fields(core.encode_field(original)), { original })
end

function TestCacheEncoding:test_round_trip_multiple_fields()
   local fields = { "VST: FabFilter: Pro-Q 3", "Processing Mode", "Processing Resolution" }
   local encoded = ""
   for _, f in ipairs(fields) do encoded = encoded .. core.encode_field(f) end

   lu.assertEquals(core.decode_fields(encoded), fields)
end

function TestCacheEncoding:test_round_trip_preserves_order()
   local fields = { "a", "bb", "ccc", "d;d" }
   local encoded = ""
   for _, f in ipairs(fields) do encoded = encoded .. core.encode_field(f) end

   local decoded = core.decode_fields(encoded)
   lu.assertEquals(#decoded, #fields)
   for i = 1, #fields do lu.assertEquals(decoded[i], fields[i]) end
end


--------------------------------------------------------------------------------
-- match_parameter
--
-- Three-tier matching: exact, then case-insensitive + whitespace-trimmed, then
-- substring.

TestMatchParameter = {}

function TestMatchParameter:test_exact_match()
   lu.assertEquals(core.match_parameter({ "Foo", "Oversampling", "Bar" }, "Oversampling"), 2)
end

function TestMatchParameter:test_case_insensitive_match()
   lu.assertEquals(core.match_parameter({ "Foo", "oversampling", "Bar" }, "Oversampling"), 2)
end

function TestMatchParameter:test_whitespace_trimmed_match()
   lu.assertEquals(core.match_parameter({ "Foo", "  Oversampling  ", "Bar" }, "Oversampling"), 2)
end

function TestMatchParameter:test_substring_fallback()
   -- Known name "Oversampling" appears inside the real "Oversampling Rate".
   lu.assertEquals(core.match_parameter({ "Gain", "Oversampling Rate" }, "Oversampling"), 2)
end

function TestMatchParameter:test_exact_beats_substring_later()
   -- An exact match at index 1 wins over a substring match at index 3.
   lu.assertEquals(core.match_parameter({ "Oversampling", "X", "Oversampling Rate" }, "Oversampling"), 1)
end

function TestMatchParameter:test_no_match_returns_nil()
   lu.assertIsNil(core.match_parameter({ "Foo", "Bar" }, "Oversampling"))
end

function TestMatchParameter:test_empty_list_returns_nil()
   lu.assertIsNil(core.match_parameter({}, "Oversampling"))
end


--------------------------------------------------------------------------------
-- same_name_set

TestSameNameSet = {}

function TestSameNameSet:test_equal_sets_in_same_order()
   lu.assertEquals(core.same_name_set({ "A", "B" }, { "A", "B" }), true)
end

function TestSameNameSet:test_equal_sets_different_order()
   lu.assertEquals(core.same_name_set({ "A", "B" }, { "B", "A" }), true)
end

function TestSameNameSet:test_different_length()
   lu.assertEquals(core.same_name_set({ "A" }, { "A", "B" }), false)
end

function TestSameNameSet:test_different_elements()
   lu.assertEquals(core.same_name_set({ "A", "B" }, { "A", "C" }), false)
end

function TestSameNameSet:test_both_empty()
   lu.assertEquals(core.same_name_set({}, {}), true)
end


--------------------------------------------------------------------------------
-- collect_device_items

TestCollectDeviceItems = {}

function TestCollectDeviceItems:test_uses_live_devices_when_present()
   local devices = { ["VST: FabFilter: Pro-C 2"] = { instances = {} } }
   local items = core.collect_device_items(devices, { "Cached A", "Cached B" })

   local as_set = {}
   for _, n in ipairs(items) do as_set[n] = true end
   lu.assertEquals(as_set["VST: FabFilter: Pro-C 2"], true)
   lu.assertEquals(as_set["Cached A"], nil)
   lu.assertEquals(#items, 1)
end

function TestCollectDeviceItems:test_falls_back_to_cached_names_when_no_live_devices()
   local items = core.collect_device_items({}, { "Cached A", "Cached B" })
   lu.assertEquals(items, { "Cached A", "Cached B" })
end

function TestCollectDeviceItems:test_empty_when_nothing_available()
   lu.assertEquals(core.collect_device_items({}, {}), {})
end


--------------------------------------------------------------------------------
-- resolve_parameter_index

TestResolveParameterIndex = {}

function TestResolveParameterIndex:test_resolves_by_name()
   local names = { "Gain", "Oversampling", "Mix" }
   lu.assertEquals(core.resolve_parameter_index(names, "Oversampling", 9), 2)
end

function TestResolveParameterIndex:test_falls_back_to_index_when_name_absent()
   local names = { "Gain", "Mix" }
   lu.assertEquals(core.resolve_parameter_index(names, "Oversampling", 9), 9)
end

function TestResolveParameterIndex:test_uses_given_index_when_no_name()
   local names = { "Gain", "Oversampling" }
   lu.assertEquals(core.resolve_parameter_index(names, nil, 1), 1)
end


--------------------------------------------------------------------------------
-- known_devices_parameters (data shape sanity)

TestKnownDevicesParameters = {}

function TestKnownDevicesParameters:test_every_entry_is_string_or_array_of_strings()
   for device_name, value in pairs(core.known_devices_parameters) do
      if (type(value) == "string") then
         lu.assertIsString(value)
      elseif (type(value) == "table") then
         for _, v in ipairs(value) do
            lu.assertIsString(v)
         end
      else
         lu.fail("Entry for " .. tostring(device_name) .. " has unexpected type " .. type(value))
      end
   end
end

function TestKnownDevicesParameters:test_vst3_pro_l_2_has_no_oversampling_entry()
   -- The VST3 Pro-L 2 build exposes no such parameter, so it must not be listed.
   lu.assertIsNil(core.known_devices_parameters["VST3: FabFilter: Pro-L 2"])
end



--------------------------------------------------------------------------------
-- known_primary / known_secondary

TestKnownPrimarySecondary = {}

function TestKnownPrimarySecondary:test_primary_is_string_for_single_param_device()
   lu.assertEquals(core.known_primary("VST: FabFilter: Pro-C 2"), "Oversampling")
end

function TestKnownPrimarySecondary:test_primary_is_first_element_for_list_device()
   lu.assertEquals(core.known_primary("VST: FabFilter: Pro-Q 3"), "Processing Mode")
end

function TestKnownPrimarySecondary:test_primary_nil_for_unknown_device()
   lu.assertIsNil(core.known_primary("VST: FabFilter: Whatever"))
end

function TestKnownPrimarySecondary:test_secondary_nil_for_single_param_device()
   lu.assertIsNil(core.known_secondary("VST: FabFilter: Pro-C 2"))
end

function TestKnownPrimarySecondary:test_secondary_is_second_element_for_list_device()
   lu.assertEquals(core.known_secondary("VST: FabFilter: Pro-Q 3"), "Processing Resolution")
end

function TestKnownPrimarySecondary:test_secondary_nil_for_unknown_device()
   lu.assertIsNil(core.known_secondary("VST: FabFilter: Whatever"))
end


--------------------------------------------------------------------------------
-- nearest_choice_index

TestNearestChoiceIndex = {}

function TestNearestChoiceIndex:test_exact_match()
   local choices = { { value = 0 }, { value = 0.5 }, { value = 1 } }
   lu.assertEquals(core.nearest_choice_index(choices, 0.5), 2)
end

function TestNearestChoiceIndex:test_picks_nearest_when_exact_missing()
   local choices = { { value = 0 }, { value = 0.4 }, { value = 1 } }
   -- 0.45 is closer to 0.4 (d=0.05) than to 1 (d=0.55).
   lu.assertEquals(core.nearest_choice_index(choices, 0.45), 2)
end

function TestNearestChoiceIndex:test_floating_point_discrepancy()
   -- Enumeration may record the max a hair below the true value_max.
   local choices = { { value = 0 }, { value = 0.9999 } }
   lu.assertEquals(core.nearest_choice_index(choices, 1.0), 2)
end

function TestNearestChoiceIndex:test_single_choice_always_index_one()
   lu.assertEquals(core.nearest_choice_index({ { value = 7 } }, 0), 1)
end

function TestNearestChoiceIndex:test_missing_value_field_treated_as_zero()
   local choices = { {}, { value = 5 } }
   lu.assertEquals(core.nearest_choice_index(choices, 5), 2)
end

function TestNearestChoiceIndex:test_empty_choices_returns_one()
   lu.assertEquals(core.nearest_choice_index({}, 3), 1)
end


--------------------------------------------------------------------------------
-- resolve_target_indices
--
-- Mirrors the logic used by "set to min/max": only the known oversampling
-- parameter(s) plus the row's selected primary/secondary are returned.

TestResolveTargetIndices = {}

function TestResolveTargetIndices:test_known_list_device_returns_primary_and_secondary()
   -- Names parallel to 1-based parameter indices.
   local names = { "Gain", "Processing Mode", "Mix", "Processing Resolution", "Output" }
   local targets = core.resolve_target_indices(names, "VST: FabFilter: Pro-Q 3", {})
   lu.assertEquals(targets, { 2, 4 })
end

function TestResolveTargetIndices:test_selected_by_index_only()
   local names = { "Gain", "Oversampling", "Mix" }
   local targets = core.resolve_target_indices(names, "Unknown Device",
      { parameter_index = 3 })
   lu.assertEquals(targets, { 3 })
end

function TestResolveTargetIndices:test_selected_by_name_uses_match_parameter()
   -- "Oversampling" should match the real "Oversampling Rate" via substring.
   local names = { "Gain", "Oversampling Rate", "Mix" }
   local targets = core.resolve_target_indices(names, "VST: FabFilter: Pro-C 2",
      { parameter_name = "Oversampling" })
   lu.assertEquals(targets, { 2 })
end

function TestResolveTargetIndices:test_deduplicates_known_and_selected()
   local names = { "Gain", "Processing Mode", "Mix", "Processing Resolution" }
   local targets = core.resolve_target_indices(names, "VST: FabFilter: Pro-Q 3",
      { parameter_name = "Processing Mode", parameter_index = 2,
        secondary_parameter_name = "Processing Resolution", secondary_parameter_index = 4 })
   -- Each index appears exactly once despite being named and indexed.
   lu.assertEquals(targets, { 2, 4 })
end

function TestResolveTargetIndices:test_includes_row_secondary_by_name()
   local names = { "Gain", "Processing Mode", "Mix", "Processing Resolution" }
   local targets = core.resolve_target_indices(names, "VST: FabFilter: Pro-Q 3",
      { parameter_name = "Gain", parameter_index = 1,
        secondary_parameter_name = "Mix", secondary_parameter_index = 3 })
   lu.assertEquals(targets, { 2, 4, 1, 3 })
end

function TestResolveTargetIndices:test_out_of_range_index_ignored()
   local names = { "Gain", "Oversampling" }
   local targets = core.resolve_target_indices(names, "Unknown Device",
      { parameter_index = 99 })
   lu.assertEquals(targets, {})
end

function TestResolveTargetIndices:test_unmatched_name_ignored()
   local names = { "Gain", "Oversampling" }
   local targets = core.resolve_target_indices(names, "Unknown Device",
      { parameter_name = "Does Not Exist" })
   lu.assertEquals(targets, {})
end


--------------------------------------------------------------------------------

os.exit(lu.LuaUnit.run())
