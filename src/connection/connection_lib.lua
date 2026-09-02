-- Shared connection helper: resolves component_id from the ambient contract
-- execution context and builds a configured client:api instance for it.
-- Every connection method (test_connection, discover_resources) goes
-- through this so credential resolution stays in one place.

local ctx = require("ctx")
local component = require("component")
local transport = require("transport")

local M = {}

-- ctx.get returns `any` — narrowed to `string` here (mirroring
-- transport.for_component's own guard) so callers passing it into a
-- string-typed function like component.get_private_context type-check.
local function current_component_id()
    local component_id = ctx.get("component_id")
    if type(component_id) ~= "string" or component_id == "" then
        return nil
    end
    return component_id
end

function M.client_for_current()
    local component_id = current_component_id()
    if not component_id then
        return nil, "component_id not in scope"
    end
    return transport.for_component(component_id)
end

-- Raw stored credential fields (private_context) for the current
-- connection — workspace/repo_slug live here alongside access_token
-- (see connection/_index.yaml's credential_schema). Needed by
-- test_connection/discover_resources to build a repo-scoped API path: a
-- Bitbucket repository access token can only ever reach its own repo's
-- endpoints, never an account-wide listing/lookup call.
function M.creds_for_current()
    local component_id = current_component_id()
    if not component_id then
        return nil, "component_id not in scope"
    end
    local creds, err = component.get_private_context(component_id)
    if err then
        return nil, "could not read connection credentials: " .. tostring(err)
    end
    if type(creds) ~= "table" then
        return nil, "connection has no stored credentials"
    end
    return creds
end

return M
