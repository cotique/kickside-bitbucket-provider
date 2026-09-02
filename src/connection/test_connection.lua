-- kickside.connection:connection test_connection — a real live call proving
-- the stored credential actually works, per
-- docs/kickside-development/04-connections-and-integrations.md ("For live
-- credential/connectivity checks call test_connection"). Calls the Bitbucket
-- Cloud "get current user" endpoint; a 200 with uuid/username means the
-- credential is valid (empirically verified 2026-09-02, see BUILD-NOTES.md).
local connection_lib = require("connection_lib")

local function test_connection(req)
    local client, err = connection_lib.client_for_current()
    if err then
        return { success = false, error = tostring(err) }
    end

    local data, gerr = client:get("/user")
    if gerr then
        return { success = false, error = gerr.message or "Bitbucket connectivity check failed" }
    end

    if type(data) == "table" and (data.uuid ~= nil or data.username ~= nil) then
        return { success = true }
    end
    return { success = false, error = "unexpected response from Bitbucket /user" }
end

return { test_connection = test_connection }
