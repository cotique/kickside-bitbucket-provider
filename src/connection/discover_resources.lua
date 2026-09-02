-- kickside.connection:connection discover_resources — returns the single
-- Bitbucket repository this credential (workspace/repo_slug, stored
-- alongside access_token — see connection/_index.yaml's credential_schema)
-- is scoped to, normalized to
-- { id, label, icon, parent_id, selectable, drillable } per
-- docs/kickside-development/04-connections-and-integrations.md#resource-discovery.
-- Always a single-item list, drillable: false — this used to call
-- GET /repositories?role=member to list every repo the credential could
-- see, but a Bitbucket repository access token (the only supported
-- credential mode) cannot call that account-wide endpoint at all (same
-- "not accessible by this authentication mechanism" error as /user — see
-- BUILD-NOTES.md); the one repo it CAN see is already fully known from the
-- stored workspace/repo_slug, so this now looks that single repo up
-- directly instead of trying to enumerate a list it was never allowed to
-- request.
--
-- normalize_repo is exported so its mapping can be unit-tested directly
-- against a fixture payload, without a live component/actor context (the
-- standalone test harness cannot exercise ctx/component_id — see
-- docs/kickside-development/13-testing.md "Harness Limits").
local connection_lib = require("connection_lib")
local types = require("types")

local M = {}

-- repo.uuid (including its curly braces) is Bitbucket's stable identifier;
-- full_name is "workspace/repo_slug", human-readable — used as the label.
function M.normalize_repo(repo)
    return {
        id = repo.uuid,
        label = repo.full_name,
        icon = types.ICON_REPO,
        parent_id = nil,
        selectable = true,
        drillable = false,
    }
end

function M.discover_resources(req)
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
        return { success = false, error = gerr.message or "could not look up the configured Bitbucket repository" }
    end
    if type(data) ~= "table" or data.uuid == nil then
        return { success = false, error = "unexpected response from Bitbucket " .. path }
    end

    return { success = true, resources = { M.normalize_repo(data) } }
end

return M
