-- kickside.contract:component get_status — delegates to
-- kickside.connection:base_connection's get_status boilerplate per
-- docs/kickside-development/04-connections-and-integrations.md ("The
-- implementation imports kickside.connection:base_connection for
-- get_status/delete boilerplate"). get_status is a read-model over public
-- component meta, not a live probe — see connection/test_connection.lua for
-- the live credential check.
--
-- NOTE: base_connection is a packed Hub module (kickside/connection); its
-- own exported function names are not directly inspectable (`wippy registry
-- show kickside.connection:base_connection --json` returns `"data": null`).
-- The one-function-per-file delegation shape below is high-confidence: the
-- real, installed kickside/github module (inspected during this build, see
-- BUILD-NOTES.md) declares the exact same separate
-- kickside.github.connection:get_status / :delete function.lua entries with
-- matching comments ("github connection - get_status"), confirming this is
-- the real wiring pattern, not a guess. What is NOT independently verified
-- is base_connection's exported function name/signature itself — assumed
-- here to be `get_status(req)` by direct analogy to that same confirmed
-- pattern.
local base_connection = require("base_connection")

local function get_status(req)
    return base_connection.get_status(req)
end

return { get_status = get_status }
