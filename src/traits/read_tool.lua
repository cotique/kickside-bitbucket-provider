-- BitbucketRead agent-tool handler: read-only access to the pull requests of
-- the single Bitbucket Cloud repository this connection is scoped to
-- (workspace/repo_slug live in the connection's own stored credentials, not
-- in the tool's arguments — see client/transport.lua's M.resolve). Mirrors
-- kickside.github.traits:read_tool's shape (a flat action enum, thin
-- per-action validation, then a client call), adapted for this module's
-- per-connection client object instead of GitHub's per-call conn argument.
--
-- list_pull_requests reuses source/pull_core.lua's own fetch_page/
-- normalize_item logic directly — the same REST call, { values, next }
-- pagination handling, and item normalization Data Sync's pull() uses —
-- instead of reimplementing it a second time. get_pull_request also reuses
-- pull_core.normalize_item for its single-item response. There is no
-- pull_core equivalent for a single comments listing (a different payload
-- shape entirely, not a pull request), so list_pull_request_comments returns
-- the raw decoded Bitbucket API page untouched, matching how
-- kickside.github.traits:read_tool returns list_issue_comments' raw GitHub
-- payload as-is.

local ctx = require("ctx")
local json = require("json")
local output = require("output")
local transport = require("transport")
local pull_core = require("pull_core")

local M = {}
M._transport = transport
M._output = output
M._pull_core = pull_core

local MAX_OUTPUT = 8000
local DEFAULT_LIMIT = 25
local MAX_LIMIT = 100

type Args = {
    action: string,
    number: string?,
    state: string?,
    limit: number?,
    cursor: string?,
}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function connection_id(): string?
    local configured = ctx.get("connection_id")
    if type(configured) == "string" and configured ~= "" then return configured end
    return nil
end

-- client:output only exposes M.redact (credential-shaped key redaction) —
-- unlike kickside.github.client:output, it has no M.encode(data, max)
-- truncate-and-serialize helper, and adding one is out of scope for this
-- change (client:output is pre-existing, tested code this pass isn't
-- authorized to extend — only client:api/transport and the new traits/
-- folder are). So the JSON-encode-with-truncation step lives here instead,
-- built on top of the existing, unmodified M._output.redact.
local function encode(data: any): string
    local redacted = M._output.redact(data)
    local text, err = json.encode(redacted)
    if err then
        return json.encode({ success = false, error = "encode error: " .. tostring(err) })
    end
    if #text > MAX_OUTPUT then
        return json.encode({ success = false, error = "response too large (" .. tostring(#text) .. " bytes); narrow the request" })
    end
    return text
end

local function fail(message: any): string
    return encode({ success = false, error = tostring(message or "request failed") })
end

local function clamp_limit(args: Args): number
    local n = tonumber(args.limit) or DEFAULT_LIMIT
    if n < 1 then n = 1 end
    if n > MAX_LIMIT then n = MAX_LIMIT end
    return math.floor(n)
end

local function require_number(args: Args): (string?, string?)
    local number = trim(args.number)
    if number == "" then return nil, "number is required" end
    return number, nil
end

local function known_action(action: string): boolean
    return action == "get_repo"
        or action == "list_pull_requests"
        or action == "get_pull_request"
        or action == "list_pull_request_comments"
end

local function repo_path(workspace: string, repo_slug: string, suffix: string): string
    return string.format("/repositories/%s/%s%s", workspace, repo_slug, suffix)
end

local function handler(args: Args): any
    args = type(args) == "table" and args or ({ action = "" } :: Args)
    local action = trim(args.action)
    if action == "" then return fail("action is required") end
    if not known_action(action) then return fail("unknown action '" .. tostring(action) .. "'") end

    local number: string? = nil
    if action == "get_pull_request" or action == "list_pull_request_comments" then
        local nerr
        number, nerr = require_number(args)
        if nerr then return fail(nerr) end
    end

    local state = trim(args.state)
    if state ~= "" and state ~= "OPEN" and state ~= "MERGED" and state ~= "DECLINED" and state ~= "SUPERSEDED" then
        return fail("state must be OPEN, MERGED, DECLINED, or SUPERSEDED")
    end

    local tp = M._transport
    local resolved, rerr = tp.resolve(connection_id())
    if rerr or not resolved then return fail(rerr or "no connection") end
    local client, workspace, repo_slug = resolved.client, resolved.workspace, resolved.repo_slug
    if not client then return fail("no connection") end

    if action == "get_repo" then
        local data, gerr = client:get(repo_path(workspace, repo_slug, ""))
        if gerr then return fail(gerr.message or "request failed") end
        return encode(data)
    end

    if action == "list_pull_requests" then
        local cursor = trim(args.cursor) ~= "" and trim(args.cursor) or nil
        local page, perr = M._pull_core.fetch_page(client, workspace, repo_slug, cursor, {
            state = state ~= "" and state or nil,
            pagelen = clamp_limit(args),
        })
        if perr then return fail(perr.message or "request failed") end
        return encode({ items = page.items, next_cursor = page.next_cursor, has_more = page.has_more })
    end

    if action == "get_pull_request" then
        local data, gerr = client:get(repo_path(workspace, repo_slug, "/pullrequests/" .. (number :: string)))
        if gerr then return fail(gerr.message or "request failed") end
        return encode(M._pull_core.normalize_item(data, workspace, repo_slug))
    end

    -- list_pull_request_comments: a `cursor` argument is the literal
    -- previous-response `next` URL (same opaque-cursor convention
    -- pull_core/M.pull use); when absent, request the first page.
    local raw_cursor = trim(args.cursor)
    local data, gerr
    if raw_cursor ~= "" then
        data, gerr = client:get(raw_cursor)
    else
        data, gerr = client:get(
            repo_path(workspace, repo_slug, "/pullrequests/" .. (number :: string) .. "/comments"),
            { query = { pagelen = clamp_limit(args) } }
        )
    end
    if gerr then return fail(gerr.message or "request failed") end
    local next_cursor = type(data) == "table" and data.next or nil
    return encode({
        values = type(data) == "table" and data.values or {},
        next_cursor = next_cursor,
        has_more = next_cursor ~= nil,
    })
end

M.handler = handler

return M
