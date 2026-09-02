-- GET /bitbucket-provider/status — static module identity for the UI page.
-- This module owns no SQL storage of its own (kickside.data:pullable's own
-- doc comment: "Engine owns cursor, lease, schedule, dedup, id-map, and sink
-- routing"), so there is no row count to report; get_status returns a fixed
-- identity/capability snapshot instead. Authn is enforced by the router
-- (token_auth + endpoint_firewall); the actor check keeps direct
-- invocations honest.
local http = require("http")
local security = require("security")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    local actor = security.actor()
    if not actor then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({ success = false, error = "authentication required" })
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        module = "cotique/bitbucket-provider",
        status = "ok",
        capabilities = { "connection", "pull_requests_source" },
    })
end

return { handler = handler }
