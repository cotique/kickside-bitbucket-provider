-- kickside.contract:deletable delete — delegates to
-- kickside.connection:base_connection's delete boilerplate. This connection
-- owns no backing tables of its own (all state is component private_context,
-- managed by the component service), so there is nothing provider-specific
-- to tear down beyond what base_connection already does generically. See
-- connection/get_status.lua for the same base_connection-export caveat.
local base_connection = require("base_connection")

local function delete(req)
    return base_connection.delete(req)
end

return { delete = delete }
