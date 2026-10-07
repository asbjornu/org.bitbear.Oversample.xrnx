--[[============================================================================
test/oversample_load_test.lua

Verifies the tool can be `require`d under a sandbox that raises on undeclared
global reads, mirroring Renoise's loader. Renoise declares only `renoise`,
`class`, and the Lua stdlib; reading any other global at load time fails. In
particular `main.lua` installs the `ProcessSlicer` global *after* requiring the
entry module, so the tool must resolve it lazily (inside a function) rather than
reading it while loading.

Run in its own process (it temporarily installs a metatable on `_G`):

    lua test/oversample_load_test.lua
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

-- luaunit must be loaded before the sandbox is installed.
local lu = require("luaunit")

-- Snapshot every global that already exists (the stdlib + luaunit) and allow it,
-- plus the two Renoise globals. Anything else must not be read at load time.
local declared = {}
for name in pairs(_G) do declared[name] = true end
declared.renoise = true
declared.class = true

local strict_globals = {
   __index = function(_, name)
      if declared[name] then return rawget(_G, name) end
      error("variable '" .. name .. "' is not declared", 2)
   end,
   __newindex = function(_, name, value)
      declared[name] = true
      rawset(_G, name, value)
   end,
}

-- Minimal host stub, sufficient for load time only: state.lua creates the cache
-- document and the entry module creates the ViewBuilder.
local builder = {}
setmetatable(builder, { __call = function() return builder end })
renoise = {
   ViewBuilder = setmetatable({
      DEFAULT_DIALOG_MARGIN = 8,
      DEFAULT_CONTROL_SPACING = 4,
      DEFAULT_CONTROL_MARGIN = 4,
      DEFAULT_CONTROL_HEIGHT = 20,
   }, { __call = function() return builder end }),
   Document = {
      create = function() return function(spec) return spec end end,
      ObservableStringList = function() return {} end,
   },
   song = function() return nil end,
   tool = function() return { preferences = {} } end,
}

-- Run `fn` with the strict sandbox active, then restore the real environment so
-- luaunit (which itself falls back to undeclared global lookups) keeps working.
local function with_strict_globals(fn)
   local previous = getmetatable(_G)
   setmetatable(_G, strict_globals)
   local ok, result = pcall(fn)
   setmetatable(_G, previous)
   return ok, result
end

-- Exercise the load once, up front, so the assertions below only inspect the
-- captured outcome (no metatable is active while luaunit runs).
package.loaded["Oversample/oversample"] = nil
local loaded_ok, loaded_module = with_strict_globals(function()
   return require("Oversample/oversample")
end)

local leaked = {}
for _, name in ipairs({
   "oversample_init", "oversample", "destroy", "state", "cache",
   "devices", "osig", "create_settings_row", "set_values",
}) do
   if rawget(_G, name) ~= nil then leaked[#leaked + 1] = name end
end

TestLoad = {}

function TestLoad:test_entry_module_loads_without_undeclared_globals()
   lu.assertTrue(loaded_ok, tostring(loaded_module))
   lu.assertIsTable(loaded_module)
   lu.assertEquals(type(loaded_module.oversample_init), "function")
   lu.assertEquals(type(loaded_module.oversample), "function")
end

function TestLoad:test_process_slicer_is_not_needed_at_load()
   -- main.lua installs the ProcessSlicer global only after requiring the tool, so
   -- the tool must not read it while loading.
   lu.assertIsNil(rawget(_G, "ProcessSlicer"))
end

function TestLoad:test_no_implementation_leaks_into_globals()
   lu.assertEquals(leaked, {}, "module leaked globals")
end

os.exit(lu.LuaUnit.run())
