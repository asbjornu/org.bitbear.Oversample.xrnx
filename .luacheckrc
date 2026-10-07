--[[
  Luacheck configuration for Oversample.

  The tool runs inside Renoise, whose runtime exposes the `renoise` global and a
  `class` helper. `ProcessSlicer` is a Renoise `class` and therefore also a
  global. Everything else lives in local module scope (Oversample.lua returns a
  module table), so no other globals are declared and any accidental leak is
  reported.

  Only unused arguments are ignored: they are chiefly unittest `self`
  parameters and notifier callbacks that cannot use the value.
--]]

globals = {
  "renoise",
  "class",
  "ProcessSlicer",
}

ignore = {
  "212", -- unused argument (unittest self, notifier parameters)
}

-- The project's own unit tests are linted with a dedicated, lenient config:
-- luaunit discovers test cases via global tables named Test*.

files = {
  ["test/oversample_core_test.lua"] = {
    globals = {
      "TestSettingsRowIdentifiers",
      "TestCacheEncoding",
      "TestMatchParameter",
      "TestSameNameSet",
      "TestCollectDeviceItems",
      "TestResolveParameterIndex",
      "TestKnownDevicesParameters",
      "TestKnownPrimarySecondary",
      "TestNearestChoiceIndex",
      "TestResolveTargetIndices",
      "TestChunkPatch",
      "TestNormalizeDeviceName",
      "TestBase64",
      "TestOsigXml",
      "TestOsigSources",
      "TestKnownOsigFixtures",
      "TestOsigIndependentFixtures",
    },
  },
  ["test/oversample_ui_test.lua"] = {
    globals = { "TestDialogLayout" },
  },
}
