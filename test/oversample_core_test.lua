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

function TestKnownDevicesParameters:test_vst3_entries_exist_for_chunk_route()
    -- VST3 builds expose no oversampling host parameter, but we still list them so
    -- the dialog auto-creates a row; the value is driven via the state-chunk route.
    -- Entries are keyed by the prefix-free plugin identity, so VST/VST3/AU share one.
    lu.assertIsString(core.known_devices_parameters["FabFilter: Pro-L 2"])
    lu.assertEquals(core.known_devices_parameters["FabFilter: Pro-L 2"], "Oversampling")
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
-- normalize_device_name (format-prefix stripping)

TestNormalizeDeviceName = {}

function TestNormalizeDeviceName:test_strips_vst3_prefix()
   lu.assertEquals(core.normalize_device_name("VST3: FabFilter: Pro-Q 3"), "FabFilter: Pro-Q 3")
end

function TestNormalizeDeviceName:test_strips_vst_prefix()
   lu.assertEquals(core.normalize_device_name("VST: FabFilter: Pro-Q 3"), "FabFilter: Pro-Q 3")
end

function TestNormalizeDeviceName:test_strips_au_prefix()
   lu.assertEquals(core.normalize_device_name("AU: FabFilter: Pro-Q 3"), "FabFilter: Pro-Q 3")
end

function TestNormalizeDeviceName:test_leaves_prefix_free_name_unchanged()
   lu.assertEquals(core.normalize_device_name("FabFilter: Pro-Q 3"), "FabFilter: Pro-Q 3")
end

function TestNormalizeDeviceName:test_known_primary_matches_any_format()
   -- A single prefix-free entry must resolve regardless of the host format prefix.
   lu.assertEquals(core.known_primary("VST3: FabFilter: Pro-C 2"), "Oversampling")
   lu.assertEquals(core.known_primary("AU: FabFilter: Pro-C 2"), "Oversampling")
   lu.assertEquals(core.known_primary("FabFilter: Pro-C 2"), "Oversampling")
end

--------------------------------------------------------------------------------
-- VST3 state-chunk patching (multi-state diff / patch / detect / osig encoding)
--
-- These operate on raw binary blobs (strings that may contain null bytes), so the
-- tests build blobs with string.char and assert byte-level results.

TestChunkPatch = {}

function TestChunkPatch:test_diff_finds_only_differing_bytes()
   local a = string.char(0, 1, 2, 3, 4)
   local b = string.char(0, 1, 9, 3, 9)
   local c = string.char(0, 1, 9, 8, 4)
   local entries = core.diff_blobs_multi({ a, b, c }, { "Off", "2x", "4x" })
   lu.assertEquals(entries, {
      { pos = 3, values = { Off = 2, ["2x"] = 9, ["4x"] = 9 } },
      { pos = 4, values = { Off = 3, ["2x"] = 3, ["4x"] = 8 } },
      { pos = 5, values = { Off = 4, ["2x"] = 9, ["4x"] = 4 } },
   })
end

function TestChunkPatch:test_patch_to_label_reconstructs_b()
   local a = string.char(0, 1, 2, 3, 4)
   local b = string.char(0, 1, 9, 3, 9)
   local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
   lu.assertEquals(core.patch_blob(a, entries, "2x"), b)
end

function TestChunkPatch:test_patch_to_off_reconstructs_a()
   local a = string.char(0, 1, 2, 3, 4)
   local b = string.char(0, 1, 9, 3, 9)
   local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
   lu.assertEquals(core.patch_blob(b, entries, "Off"), a)
end

function TestChunkPatch:test_patch_leaves_already_targeted_blob_untouched()
   local a = string.char(0, 1, 2, 3, 4)
   local b = string.char(0, 1, 9, 3, 9)
   local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
   lu.assertEquals(core.patch_blob(a, entries, "Off"), a)
   lu.assertEquals(core.patch_blob(b, entries, "2x"), b)
end

function TestChunkPatch:test_patch_sets_mapped_bytes_and_preserves_unmapped_bytes()
   local a = string.char(0, 1, 2, 3, 4)
   local b = string.char(0, 1, 9, 3, 9)
   local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
   -- Unknown current values are overwritten only at learned positions.
   local weird = string.char(0, 7, 8, 3, 4)
   lu.assertEquals(core.patch_blob(weird, entries, "2x"), string.char(0, 7, 9, 3, 9))
end

function TestChunkPatch:test_detects_each_label_after_patching_between_states()
   local blobs = { string.char(0, 0, 0), string.char(0, 128, 63), string.char(0, 0, 64) }
   local labels = { "Off", "2x", "4x" }
   local entries = core.diff_blobs_multi(blobs, labels)
   for _, source in ipairs(blobs) do
      for i, label in ipairs(labels) do
         local patched = core.patch_blob(source, entries, label)
         lu.assertEquals(patched, blobs[i])
         lu.assertEquals(core.detect_label(patched, entries), label)
      end
   end
end

function TestChunkPatch:test_handles_null_bytes()
   -- Blobs may contain embedded zeros; diff/patch must stay byte-accurate.
   local a = string.char(0, 0, 255, 0)
   local b = string.char(0, 0, 128, 0)
   local c = string.char(0, 0, 0, 0)
   local entries = core.diff_blobs_multi({ a, b, c }, { "Off", "2x", "4x" })
   lu.assertEquals(entries, { { pos = 3, values = { Off = 255, ["2x"] = 128, ["4x"] = 0 } } })
   lu.assertEquals(core.patch_blob(a, entries, "2x"), b)
   lu.assertEquals(core.patch_blob(b, entries, "4x"), c)
end

function TestChunkPatch:test_empty_entries_is_noop()
   local a = string.char(1, 2, 3)
   lu.assertEquals(core.patch_blob(a, {}, "2x"), a)
   lu.assertIsNil(core.detect_label(a, {}))
end

function TestChunkPatch:test_patch_skips_unknown_targets_and_out_of_range_positions()
   local blob = string.char(1, 2, 3)
   local entries = {
      { pos = 0, values = { ["2x"] = 9 } },
      { pos = 2, values = { Off = 2 } },
      { pos = 3, values = { ["2x"] = 0 } },
      { pos = 4, values = { ["2x"] = 9 } },
   }
   lu.assertEquals(core.patch_blob(blob, entries, "missing"), blob)
   lu.assertEquals(core.patch_blob(blob, entries, "2x"), string.char(1, 2, 0))
end

function TestChunkPatch:test_diff_uses_shortest_blob_length()
   lu.assertEquals(core.diff_blobs_multi({ string.char(1, 2, 3), string.char(1, 4) },
      { "Off", "2x" }), { { pos = 2, values = { Off = 2, ["2x"] = 4 } } })
end

function TestChunkPatch:test_diff_requires_multiple_blobs_and_matching_labels()
   lu.assertEquals(core.diff_blobs_multi({}, {}), {})
   lu.assertEquals(core.diff_blobs_multi({ "a" }, { "Off" }), {})
   lu.assertEquals(core.diff_blobs_multi({ "a", "b" }, { "Off" }), {})
   lu.assertEquals(core.diff_blobs_multi({ "a", "a" }, { "Off", "2x" }), {})
end

function TestChunkPatch:test_osig_encode_decode_round_trip()
   local entries = {
      { pos = 3, values = { Off = 2, ["2x"] = 9, ["4x"] = 128 } },
      { pos = 5, values = { Off = 4, ["2x"] = 9, ["4x"] = 9 } },
      { pos = 1024, values = { ["Mode; Low / Off"] = 0, ["Mode; High / 4x"] = 255 } },
   }
   local encoded = core.encode_osig(entries)
   local decoded = core.decode_osig(encoded)
   lu.assertEquals(decoded, entries)
end

function TestChunkPatch:test_osig_decode_splits_nul_delimited_fields()
   -- Literal NULs inside pattern character classes fail on Lua 5.1/LuaJIT.
   local field = table.concat({ "1024", "Off", "0", "Mode; High / 4x", "255" }, "\0")
   lu.assertEquals(core.decode_osig(core.encode_field(field)), {
      { pos = 1024, values = { Off = 0, ["Mode; High / 4x"] = 255 } },
   })
end

function TestChunkPatch:test_osig_decode_ignores_malformed()
    local encoded = core.encode_field("not,an,entry") ..
       core.encode_field(table.concat({ "bad", "Off", "0" }, "\0")) ..
       core.encode_field(table.concat({ "3", "Off", "bad" }, "\0")) ..
       core.encode_field(table.concat({ "3", "Off", "0", "2x" }, "\0")) ..
       core.encode_field(table.concat({ "5", "Off", "0" }, "\0"))
    lu.assertEquals(core.decode_osig(encoded), { { pos = 5, values = { Off = 0 } } })
end

function TestChunkPatch:test_osig_decode_rejects_out_of_range_bytes_and_positions()
    -- A malformed cached signature (byte 999, zero/negative/fractional position) must be
    -- dropped rather than stored, so patch_blob's string.char never raises mid-Set.
    local valid = table.concat({ "1", "Off", "99" }, "\0")
    local bad_byte = table.concat({ "1", "Off", "999" }, "\0")
    local bad_pos = table.concat({ "0", "Off", "5" }, "\0")
    local fractional = table.concat({ "2.5", "Off", "5" }, "\0")
    local decoded = core.decode_osig(core.encode_field(valid) .. core.encode_field(bad_byte)
       .. core.encode_field(bad_pos) .. core.encode_field(fractional))
    lu.assertEquals(decoded, { { pos = 1, values = { Off = 99 } } })
end

function TestKnownDevicesParameters:test_known_devices_parameters_excludes_devices_without_signature()
    -- Pro-C 3 was recognised as a device but has no verified VST3 chunk signature; its
    -- VST3 row would dead-end on Set, so it must not be recognised until a signature exists.
    lu.assertIsNil(core.known_devices_parameters["FabFilter: Pro-C 3"])
    lu.assertNotEquals(core.known_devices_parameters["FabFilter: Pro-C 2"], nil)
end

function TestChunkPatch:test_detect_label_returns_nil_when_no_byte_matches()
     -- Non-empty entries, but the blob aligns with none of the learned bytes:
     -- best_score stays 0, so detection must report failure rather than guess.
     local entries = core.diff_blobs_multi({ string.char(9, 9, 9), string.char(1, 2, 3) },
        { "A", "B" })
     lu.assertIsNil(core.detect_label(string.char(0, 0, 0), entries))
end

function TestChunkPatch:test_patch_splices_large_blob_around_scattered_positions()
     -- A 200-byte blob with three scattered positions changed to a new target.
     local orig = {}
     for i = 1, 200 do orig[i] = string.char(i % 256) end
     local orig_blob = table.concat(orig)
     local tarr = {}
     for i = 1, 200 do tarr[i] = orig[i] end
     tarr[1] = string.char(77)
     tarr[100] = string.char(88)
     tarr[200] = string.char(99)
     local target_blob = table.concat(tarr)
     local entries = core.diff_blobs_multi({ orig_blob, target_blob }, { "Off", "2x" })
     local patched = core.patch_blob(orig_blob, entries, "2x")
     lu.assertEquals(patched, target_blob)
     lu.assertEquals(string.len(patched), 200)
     -- Unchanged runs around the patch points are preserved exactly (splice path).
     lu.assertEquals(string.sub(patched, 2, 99), string.sub(orig_blob, 2, 99))
     lu.assertEquals(string.sub(patched, 101, 199), string.sub(orig_blob, 101, 199))
end

function TestChunkPatch:test_patch_returns_original_when_no_entries_apply()
     -- No position maps to the requested target, so nothing is patched and the
     -- original blob is returned without rebuilding it byte-by-byte.
     local blob = string.char(1, 2, 3)
     local entries = { { pos = 2, values = { Off = 2 } } }
     lu.assertEquals(core.patch_blob(blob, entries, "missing"), blob)
end

function TestChunkPatch:test_detect_label_breaks_ties_deterministically()
     -- Both labels score identically; the result must be the lexicographically
     -- smallest label, independent of hash iteration order in Lua 5.1/JIT.
     local entries = {
        { pos = 1, values = { ["Zebra"] = 1, ["Alpha"] = 1 } },
        { pos = 2, values = { ["Zebra"] = 2, ["Alpha"] = 2 } },
     }
     lu.assertEquals(core.detect_label(string.char(1, 2), entries), "Alpha")
end



--------------------------------------------------------------------------------
-- base64 codec (b64encode / b64decode)
--
-- VST3 chunks are exchanged base64-encoded, so the codec must round-trip raw
-- binary (including null bytes) exactly and follow RFC 4648 padding.

TestBase64 = {}

function TestBase64:test_known_vectors()
    lu.assertEquals(core.b64encode("M"), "TQ==")
    lu.assertEquals(core.b64encode("Ma"), "TWE=")
    lu.assertEquals(core.b64encode("Man"), "TWFu")
    lu.assertEquals(core.b64decode("TQ=="), "M")
    lu.assertEquals(core.b64decode("TWE="), "Ma")
    lu.assertEquals(core.b64decode("TWFu"), "Man")
end

function TestBase64:test_round_trips_all_byte_values()
    local all = ""
    for i = 0, 255 do all = all .. string.char(i) end
    lu.assertEquals(core.b64decode(core.b64encode(all)), all)
end

function TestBase64:test_round_trips_various_lengths()
    for len = 0, 6 do
        local blob = string.rep(string.char(0xAB, 0xCD, 0xEF, 0x01), len)
        lu.assertEquals(core.b64decode(core.b64encode(blob)), blob)
    end
end

function TestBase64:test_decode_strips_whitespace_and_newlines()
    -- Renoise sometimes wraps the encoded chunk; the decoder must tolerate it.
    lu.assertEquals(core.b64decode("TQ ==\n"), "M")
    lu.assertEquals(core.b64decode("  TWFu  "), "Man")
end


--------------------------------------------------------------------------------
-- VST3 XML patching (patch_osig_xml / detect_label_xml / first_label)
--
-- The chunk lives base64-encoded inside <ParameterChunk><![CDATA[…]]></ParameterChunk>;
-- the helpers decode, patch/detect on the binary, then re-encode.

TestOsigXml = {}

function TestOsigXml:make_xml(bin)
    local b64 = core.b64encode(bin)
    return "<DeviceChunkMachineData><ParameterChunk><![CDATA[" .. b64 .. "]]></ParameterChunk></DeviceChunkMachineData>"
end

function TestOsigXml:test_patch_reencodes_and_preserves_structure()
    local a = string.char(0, 1, 2, 3, 4)
    local b = string.char(0, 1, 9, 3, 9)
    local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
    local xml = self:make_xml(a)
    local patched = core.patch_osig_xml(xml, entries, "2x")
    lu.assertNotIsNil(patched)
    lu.assertNotIsNil(string.match(patched, "<ParameterChunk><!%[CDATA%["))
    local nb64 = string.match(patched, "CDATA%[([%s%S]-)%]%]")
    lu.assertEquals(core.b64decode(nb64), b)
end

function TestOsigXml:test_patch_returns_nil_without_parameter_chunk()
    local entries = core.diff_blobs_multi({ string.char(0, 1, 2), string.char(0, 1, 9) },
       { "Off", "2x" })
    lu.assertIsNil(core.patch_osig_xml("<SomeOtherTag/>", entries, "2x"))
end

function TestOsigXml:test_patch_returns_nil_when_already_target()
    local a = string.char(0, 1, 2, 3, 4)
    local b = string.char(0, 1, 9, 3, 9)
    local entries = core.diff_blobs_multi({ a, b }, { "Off", "2x" })
    local xml = self:make_xml(b)
    lu.assertIsNil(core.patch_osig_xml(xml, entries, "2x"))
end

function TestOsigXml:test_detect_reads_label_from_xml()
    local b = string.char(0, 1, 9, 3, 9)
    local entries = core.diff_blobs_multi({ string.char(0, 1, 2, 3, 4), b }, { "Off", "2x" })
    local xml = self:make_xml(b)
    lu.assertEquals(core.detect_label_xml(xml, entries), "2x")
end

function TestOsigXml:test_detect_returns_nil_without_parameter_chunk()
    local entries = core.diff_blobs_multi({ string.char(0, 1, 2), string.char(0, 1, 9) },
       { "Off", "2x" })
    lu.assertIsNil(core.detect_label_xml("<SomeOtherTag/>", entries))
end

function TestOsigXml:test_first_label_and_empty_cases()
    local entries = core.diff_blobs_multi({ string.char(0, 1), string.char(9, 9) }, { "Off", "2x" })
    -- first_label returns next(entries[1].values); the concrete key order is
    -- implementation-defined (hash-based in Lua 5.1/JIT), so accept either label.
    local fl = core.first_label(entries)
    lu.assertNotIsNil(fl)
    lu.assertTrue(fl == "Off" or fl == "2x", "unexpected first label: " .. tostring(fl))
    lu.assertIsNil(core.first_label({}))
    lu.assertIsNil(core.first_label(nil))
end


--------------------------------------------------------------------------------
-- osig dropdown sources (osig_choices / osig_axes)
--
-- The UI builds its oversampling dropdowns from these; they must return the
-- declared labels/axes in order and nil for devices without a definition.

TestOsigSources = {}

function TestOsigSources:test_choices_in_known_order_with_indices()
    lu.assertEquals(core.osig_choices("FabFilter: Pro-C 2"),
       { { label = "Off", value = 1 }, { label = "2x", value = 2 }, { label = "4x", value = 3 } })
end

function TestOsigSources:test_choices_nil_for_unknown_device()
    lu.assertIsNil(core.osig_choices("FabFilter: Unknown"))
end

function TestOsigSources:test_axes_for_multi_axis_device()
    lu.assertEquals(core.osig_axes("FabFilter: Saturn 2"), {
        { name = "High Quality", labels = { "Off", "Good", "Superb" } },
        { name = "Linear Phase", labels = { "Off", "On" } },
    })
end

function TestOsigSources:test_axes_nil_for_single_axis_device()
    lu.assertIsNil(core.osig_axes("FabFilter: Pro-C 2"))
end


--------------------------------------------------------------------------------

os.exit(lu.LuaUnit.run())
