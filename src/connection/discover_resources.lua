-- kickside.connection:connection discover_resources — lists repositories the
-- credential can see, normalized to
-- { id, label, icon, parent_id, selectable, drillable } per
-- docs/kickside-development/04-connections-and-integrations.md#resource-discovery.
-- Flat list, drillable: false — no workspace/group hierarchy (out of scope,
-- see BUILD-NOTES.md).
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

    local resources = {}
    local cursor = "/repositories?role=member&pagelen=100"
    while cursor do
        local data, gerr = client:get(cursor)
        if gerr then
            return { success = false, error = gerr.message or "could not list Bitbucket repositories" }
        end
        for _, repo in ipairs(type(data) == "table" and data.values or {}) do
            resources[#resources + 1] = M.normalize_repo(repo)
        end
        cursor = type(data) == "table" and data.next or nil
    end

    return { success = true, resources = resources }
end

return M
