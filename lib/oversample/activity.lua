-- A tiny "the tool is busy" signal. Low-level modules (devices, parameters)
-- announce that a scan or action is in flight without knowing how the UI
-- reflects it; the layout module subscribes and toggles the controls. This
-- inverts the dependency so those modules stay UI-agnostic and neither has to
-- depend on the layout module (which would close a cycle).
return function()
    local active = false
    local listeners = {}
    local M = {}

    function M.set(value)
        active = value and true or false
        for _, listener in ipairs(listeners) do
            listener(active)
        end
    end

    function M.on_change(listener)
        listeners[#listeners + 1] = listener
    end

    return M
end
