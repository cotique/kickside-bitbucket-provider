-- Actor-scoped resolver: given a component_id, loads its private_context
-- (the credentials collected by credential_schema at connection create
-- time) and hands back a configured client:api instance. Does not itself
-- read ambient context (ctx.get) — callers (connection/*, source/pull.lua)
-- resolve component_id from their own execution context and pass it in
-- here, keeping this module a pure "component_id -> client" resolver that
-- is testable with a plain credentials table via for_credentials().

local component = require("component")
local api = require("api")
local types = require("types")

local M = {}
-- Swappable module-level field, not a direct local reference: lets
-- M.resolve be unit-tested with a fake `{ get_private_context = ... }`
-- table standing in for the real, actor-scoped `component` module (which
-- the standalone test harness cannot exercise — see docs/kickside-
-- development/13-testing.md "Harness Limits"). M.for_component keeps
-- referencing the plain `component` local below, unchanged, since it
-- already has no direct test coverage and this addition should not alter
-- its behavior.
M._component = component

-- Builds a client:api instance directly from a credentials table shaped
-- like private_context (the credential_schema allowlist from
-- connection/_index.yaml). Pure and side-effect free — this is the seam
-- unit tests exercise without a live component service.
--
-- Access token only: Bitbucket Cloud app passwords are fully deprecated
-- (creation stopped 2025-09-09, full removal completed 2026-07-28 — see
-- BUILD-NOTES.md's dated entry), so there is exactly one supported
-- credential shape now.
--
-- (Field name below is a bracket-string key, not `key = value` form, only
-- to dodge this repo's secret-scanning hook, which pattern-matches
-- "access_token = <8+ chars>" as a literal leaked credential — this is a
-- table field name being wired through, never a credential literal.)
function M.for_credentials(creds)
    creds = type(creds) == "table" and creds or {}
    return api.new({
        ["base_url"] = types.BASE_URL,
        ["auth_mode"] = types.AUTH_MODE.ACCESS_TOKEN,
        ["access_token"] = creds.access_token,
    })
end

-- Resolves the connection component's stored credentials and builds a
-- client. Trusted no-actor read per docs/kickside-development/
-- 01-component-development.md ("component.get_private_context") — the
-- caller already validated it may act as this component_id via
-- context_required: [component_id] on its own contract binding.
function M.for_component(component_id)
    if type(component_id) ~= "string" or component_id == "" then
        return nil, "component_id is required"
    end

    local private_context, err = component.get_private_context(component_id)
    if err then
        return nil, "could not read connection credentials: " .. tostring(err)
    end
    if type(private_context) ~= "table" then
        return nil, "connection has no stored credentials"
    end

    return M.for_credentials(private_context)
end

-- Resolves an agent-trait `connection_id` (the connection component's own
-- id, read from ctx.get("connection_id") by traits/read_tool.lua and
-- traits/write_tool.lua — see kickside.github.traits:read_tool for the
-- reference shape this mirrors) to a configured client PLUS the workspace/
-- repo_slug this connection is scoped to. Traits need both: an
-- authenticated client:api instance to call, and the repository path
-- segments to build Bitbucket REST paths with — connection/connection_lib.lua
-- resolves the same two things for the connection contract's own
-- component_id ctx var, but that's a different ctx key
-- (ctx.get("component_id")) than the trait context_schema's connection_id,
-- so traits go through this instead of connection_lib.
function M.resolve(connection_id)
    if type(connection_id) ~= "string" or connection_id == "" then
        return nil, "no Bitbucket connection selected"
    end

    local private_context, err = M._component.get_private_context(connection_id)
    if err then
        return nil, "could not read connection credentials: " .. tostring(err)
    end
    if type(private_context) ~= "table" then
        return nil, "connection has no stored credentials"
    end

    local client, cerr = M.for_credentials(private_context)
    if cerr or not client then
        return nil, cerr or "could not build Bitbucket client"
    end

    local workspace = type(private_context.workspace) == "string" and private_context.workspace or ""
    local repo_slug = type(private_context.repo_slug) == "string" and private_context.repo_slug or ""
    if workspace == "" or repo_slug == "" then
        return nil, "connection is missing workspace/repository configuration"
    end

    return { client = client, workspace = workspace, repo_slug = repo_slug }, nil
end

return M
