--[[
  Luacheck configuration for Oversample.

  The tool runs inside Renoise, whose runtime exposes the `renoise` global and a
  `class` helper. The tool also defines its entry points as module-level globals
  on purpose, so those are declared here to avoid false "undefined/mutating
  global" warnings. With these declared, Luacheck still catches genuine mistakes
  such as typos in global names or use of undeclared globals.

  The remaining warnings are pre-existing style nits in this legacy codebase that
  cannot be unit-tested outside of Renoise, so they are intentionally ignored to
  keep this check focused on real problems.
--]]

globals = {
  "renoise",
  "class",
  "ProcessSlicer",
  -- Project entry points defined as module-level globals.
  "oversample",
  "destroy",
  "set_values",
  "create_settings_row",
  "create_settings_row_identifiers",
  "device_selected",
  "parameter_selected",
  "parameter_value_changed",
  "enumerate_tracks",
  "enumerate_devices",
  "enumerate_parameters",
  "add_device_items",
  "add_device_items_init",
  -- Internal helpers and Renoise callbacks defined as module-level globals on
  -- purpose: they are referenced before their definition (forward references),
  -- and oversample_init/oversample are invoked from main.lua. A local would
  -- resolve to nil at those earlier call sites, so they stay global.
  "oversample_init",
  "oversample_on_new_song",
  "load_tool_cache",
  "save_tool_cache",
  "save_global_cache",
  "save_global_device_name_cache",
  "prune_parameter_cache",
  "on_device_preset_changed",
  "render_settings_rows",
  "update_secondary",
  "get_parameters",
  "count_parameters",
  "extreme_values",
  "set_main_buttons_active",
}

-- The test/ directory is the unit-test suite (vendored luaunit plus the test
-- file). These are excluded from linting so CI stays focused on the tool code.
exclude_files = {
  "test/**",
}

ignore = {
  "211", -- unused variable
  "212", -- unused argument
  "213", -- unused loop variable
  "421", -- shadowing upvalue
  "431", -- shadowing definition
  "542", -- empty if branch
  "631", -- line too long
}
