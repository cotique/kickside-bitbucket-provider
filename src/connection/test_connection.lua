-- kickside.connection:connection test_connection — a real live call proving
-- the stored credential actually works, per
-- docs/kickside-development/04-connections-and-integrations.md ("For live
-- credential/connectivity checks call test_connection"). Calls
-- GET /repositories/{workspace}/{repo_slug} — NOT the account-wide GET
-- /user endpoint this used to call. A Bitbucket repository access token
-- (the only supported credential mode now that app passwords are
-- deprecated, see BUILD-NOTES.md) is scoped to exactly one repository and
-- gets a real "This API is not accessible by this authentication
-- mechanism" error from /user — confirmed live 2026-09-02 against a real
-- repository token. A 200 with a uuid means the credential is valid for
-- the configured repo.
local connection_lib = require("connection_lib")

local function test_connection(req)
    local client, err = connection_lib.client_for_current()
    if err then
        return { success = false, error = tostring(err) }
    end

    local creds, cerr = connection_lib.creds_for_current()
    if cerr then
        return { success = false, error = tostring(cerr) }
    end

    local workspace = creds.workspace
    local repo_slug = creds.repo_slug
    if type(workspace) ~= "string" or workspace == ""
        or type(repo_slug) ~= "string" or repo_slug == "" then
        return { success = false, error = "workspace and repository are required" }
    end

    local path = string.format("/repositories/%s/%s", workspace, repo_slug)
    local data, gerr = client:get(path)
    if gerr then
        return { success = false, error = gerr.message or "Bitbucket connectivity check failed" }
    end

    if type(data) == "table" and data.uuid ~= nil then
        return { success = true }
    end
    return { success = false, error = "unexpected response from Bitbucket " .. path }
end

return { test_connection = test_connection }
