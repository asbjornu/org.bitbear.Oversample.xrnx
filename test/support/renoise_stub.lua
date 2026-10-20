-- Shared Renoise host stub for the tool's test suites.
--
-- Models the small slice of the Renoise API the tool touches: a ViewBuilder
-- whose controls track visible-child sizing (so layout tests can assert widths),
-- a Document factory, and the custom-dialog entry point. It is NOT native
-- rendering: font metrics, clipping, and notifier timing are not modelled.
--
-- `build(config)` returns a host table:
--   config.spacing         control spacing (default 4)
--   config.control_height  control height (default 20)
--   config.watch           called after any control property assignment
--   config.song            renoise.song() implementation (default { tracks = {} })
--
--   host.renoise  the `renoise` table to install as the global
--   host.builder  the ViewBuilder instance; host.builder.views maps id -> view
--   host.views    alias of host.builder.views
--   host.root     the view passed to show_custom_dialog (nil until shown)
return function(config)
   config = config or {}
   local spacing = config.spacing or 4
   local control_height = config.control_height or 20
   local watch = config.watch
   local song = config.song or function() return { tracks = {} } end

   local host = { views = {} }
   local builder = { views = host.views }

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
      local natural = axis == "height" and control_height or 0
      if horizontal or state.kind == "column" then
         natural = ((axis == "width") == horizontal) and
             (sum + math.max(count - 1, 0) * (state.spacing or 0)) or maximum
         natural = natural + 2 * (state.margin or 0)
      end
      return math.max(state[axis] or 0, natural)
   end

   for _, kind in ipairs({"row", "column", "horizontal_aligner", "text",
       "multiline_text", "popup", "slider", "button", "space"}) do
      builder[kind] = function(_, spec)
         spec = spec or {}
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
                  state.width = math.max(state.width or 0, #value * control_height * 0.3)
               end
               if watch then watch() end
            end
         })
         if spec.id then
            if host.views[spec.id] then error("Duplicate view ID: " .. spec.id) end
            host.views[spec.id] = view
         end
         return view
      end
   end

   -- Minimal ObservableStringList: array storage plus the size/insert/remove API
   -- the cache module relies on. from_string/to_string are no-ops here.
   local function observable_string_list()
      local list = {}
      function list:size() return #list end
      function list:insert(value) list[#list + 1] = value end
      function list:remove(index) table.remove(list, index) end
      function list:from_string() end
      function list:to_string() return "" end
      return list
   end

   -- Minimal Document: the spec table's fields plus from_string/to_string.
   local function document(spec)
      local doc = spec or {}
      function doc:from_string() end
      function doc:to_string() return "" end
      return doc
   end

   -- The tool's preferences object is stable across calls and carries the string
   -- lists the cache module reads/writes.
   local host_tool = {
      preferences = {
         debug = true,
         cached_parameters = observable_string_list(),
         cached_device_names = observable_string_list(),
         osig = observable_string_list(),
      },
   }

   host.renoise = {
      ViewBuilder = setmetatable({DEFAULT_DIALOG_MARGIN = 8,
         DEFAULT_CONTROL_SPACING = spacing, DEFAULT_CONTROL_MARGIN = 4,
         DEFAULT_CONTROL_HEIGHT = control_height}, {
         __call = function() return builder end
      }),
      Document = {
         create = function() return document end,
         ObservableStringList = observable_string_list
      },
      song = song,
      tool = function() return host_tool end,
      app = function() return {
         show_custom_dialog = function(_, _, view)
            host.root = view
            return {visible = true, close = function() end}
         end
      } end
   }
   host.builder = builder
   return host
end
