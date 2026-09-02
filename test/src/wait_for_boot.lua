local registry = require("registry")
local time = require("time")

-- This module owns no SQL tables, so there is no migration to poll for.
-- Instead, wait for the module's own connection binding entry to be live in
-- the registry before the suites run — a proxy for "the workspace
-- replacement finished loading and the dependency graph resolved".
local function run()
    for _ = 1, 300 do
        local entry, err = registry.get("cotique.bitbucket_provider.connection:bitbucket_connection")
        if not err and entry then return true end
        time.sleep("100ms")
    end
    error("cotique.bitbucket_provider.connection:bitbucket_connection did not register within 30s")
end

return { run = run }
