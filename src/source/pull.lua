-- ============================================================================
-- PARTIALLY VERIFIED ENVELOPE — read BUILD-NOTES.md "OPEN:
-- kickside.data:pullable request/response shape" before changing pull() or
-- pull_keys() below.
--
-- We do NOT have access to kickside.data:pullable's real Lua source. The
-- reference module (kickside/github) is a packed Hub module —
-- `wippy registry show <id> --json` returns "data": null for every one of
-- its entries, confirmed again during this build (see BUILD-NOTES.md).
--
-- CONFIRMED live, by booting this module in the standalone test harness
-- against the real, installed kickside.data:pullable contract definition
-- (not a guess): the contract accepts exactly ONE bound method, `pull`.
-- Attempting to also bind `pull_keys` under kickside.data:pullable in
-- source/_index.yaml's contract.binding is REJECTED at registry-commit time
-- ("bound method is not defined in contract definition"). pull_keys() below
-- is therefore NOT wired through the pullable contract — it is kept as a
-- plain, unbound function.lua entry only because kickside/github ships the
-- identical shape (a pull_keys function.lua entry alongside pull_items),
-- but exactly how Data Sync's reconcile path is meant to reach it is still
-- open — see BUILD-NOTES.md.
--
-- The request/response ENVELOPE for pull() itself — request
-- { config, cursor }, success { success = true, items, next_cursor,
-- has_more }, failure { success = false, error = { code, message,
-- retriable, scope } } — is still INFERRED BY ANALOGY to the real, verified
-- kickside.data:writable.write envelope (the template's own src/sink/
-- write.lua before this module removed the demo sink; error shape
-- confirmed generic across kickside.data:* per docs/kickside-development/
-- 02-contracts-and-ports.md). The contract's method LIST is now confirmed;
-- the request/response SHAPE of that one method is not.
--
-- If this envelope is wrong, only pull()/pull_keys() below need to change.
-- pull_core.lua (REST calls, pagination, item normalization) does not
-- depend on this guess at all and is independently unit-tested against
-- fakes — see pull_core_test.lua.
-- ============================================================================

local pull_core = require("pull_core")
local transport = require("transport")
local ctx = require("ctx")

local function resolve_client()
    local component_id = ctx.get("component_id")
    if not component_id then return nil, "component_id not in scope" end
    return transport.for_component(component_id)
end

local function invalid_request(message)
    return { success = false, error = { code = "invalid_request", message = message, retriable = false, scope = "flow" } }
end

local function connection_failure(message)
    return {
        success = false,
        error = { code = "connection_unavailable", message = tostring(message), retriable = true, scope = "connection" },
    }
end

local function run(req, keys_only)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}
    local cursor = type(req.cursor) == "string" and req.cursor or nil

    local workspace = config.workspace
    local repo_slug = config.repo_slug
    if type(workspace) ~= "string" or workspace == "" then
        return invalid_request("config.workspace is required")
    end
    if type(repo_slug) ~= "string" or repo_slug == "" then
        return invalid_request("config.repo_slug is required")
    end

    local client, cerr = resolve_client()
    if cerr then return connection_failure(cerr) end

    local page, perr = pull_core.fetch_page(client, workspace, repo_slug, cursor, {
        state = config.state,
        pagelen = config.pagelen,
        keys_only = keys_only,
    })
    if perr then
        -- perr is already a DataError { code, message, retriable, scope }
        -- (client:api returns it in that shape) — pass it straight through.
        return { success = false, error = perr }
    end

    return { success = true, items = page.items, next_cursor = page.next_cursor, has_more = page.has_more }
end

local function pull(req)
    return run(req, false)
end

local function pull_keys(req)
    return run(req, true)
end

return { pull = pull, pull_keys = pull_keys }
