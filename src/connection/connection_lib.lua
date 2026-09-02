-- Shared connection helper: resolves component_id from the ambient contract
-- execution context and builds a configured client:api instance for it.
-- Every connection method (test_connection, discover_resources) goes
-- through this so credential resolution stays in one place.

local ctx = require("ctx")
local transport = require("transport")

local M = {}

function M.client_for_current()
    local component_id = ctx.get("component_id")
    if not component_id then
        return nil, "component_id not in scope"
    end
    return transport.for_component(component_id)
end

return M
