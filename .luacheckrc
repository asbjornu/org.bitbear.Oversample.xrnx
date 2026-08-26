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
