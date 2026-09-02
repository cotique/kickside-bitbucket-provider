-- kickside.data:pullable.pull / Data Sync reconcile pull_keys for
-- Bitbucket Cloud pull requests.
--
-- The request/response envelope is now CONFIRMED against the real,
-- unpacked kickside/providers monorepo source — see source/pull_core.lua's
-- header comment and BUILD-NOTES.md "RESOLVED: kickside.data:pullable
-- envelope". pull_core.lua owns the whole implementation (config
-- validation, connection resolution, pagination, normalization, envelope
-- wrapping); this file is a thin pass-through, matching the real reference
-- modules' own pull_items.lua/pull_keys.lua split.

local pull_core = require("pull_core")

local function pull(req)
    return pull_core.pull(req)
end

local function pull_keys(req)
    return pull_core.pull_keys(req)
end

return { pull = pull, pull_keys = pull_keys }
