-- BitbucketWrite agent-tool handler: create_pull_request, update_pull_request,
-- decline_pull_request, create_comment against the single Bitbucket Cloud
-- repository this connection is scoped to (workspace/repo_slug resolved from
-- the connection's own stored credentials via client/transport.lua's
-- M.resolve — never a tool argument). Mirrors
-- kickside.github.traits:write_tool's shape and restraint: a flat action
-- enum, thin per-action validation, then a client:post/:put call. Never
-- merges, approves, deletes, or reaches any repository/branch/settings/
-- webhook/pipeline write surface — those are out of scope for this
-- capability entirely, matching GitHub's own writer trait.
--
-- Request/response field shapes below were confirmed live in the browser
-- against the real, current Bitbucket Cloud REST API docs
-- (https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/)
-- during this build — NOT by making a live write call against a real
-- repository (no test repo / write-scoped credential exists for this pass;
-- see BUILD-NOTES.md's write-access entry for exactly what was confirmed and
-- the disclosed gap this leaves).
--
-- decline is its own endpoint (POST .../decline, empty body), confirmed live
-- in the docs — Bitbucket's update endpoint has no state-transition field at
-- all ("Only open pull requests can be mutated" is the update endpoint's own
-- entire state-related statement), so update_pull_request never accepts a
-- state/close argument; decline_pull_request is the real, separate action.
-- Reviewers are deliberately not exposed here: Bitbucket's create-PR
-- reviewers field takes an array of user UUIDs, not usernames or display
-- names, which an agent has no reliable way to obtain through this trait's
-- own read surface — a real capability gap, left out rather than shipped
-- half-working.

local ctx = require("ctx")
local json = require("json")
local output = require("output")
local transport = require("transport")

local M = {}
M._transport = transport
M._output = output

local MAX_OUTPUT = 8000

type Args = {
    action: string,
    number: string?,
    title: string?,
    description: string?,
    source_branch: string?,
    destination_branch: string?,
    close_source_branch: boolean?,
    body: string?,
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
-- see traits/read_tool.lua's matching comment for why the JSON-encode-with-
-- truncation step lives here instead of an added M.encode there.
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

local function require_number(args: Args): (string?, string?)
    local number = trim(args.number)
    if number == "" then return nil, "number is required" end
    return number, nil
end

local function known_action(action: string): boolean
    return action == "create_pull_request"
        or action == "update_pull_request"
        or action == "decline_pull_request"
        or action == "create_comment"
end

local function repo_path(workspace: string, repo_slug: string, suffix: string): string
    return string.format("/repositories/%s/%s%s", workspace, repo_slug, suffix)
end

-- POST body per the confirmed "Create a pull request" shape: minimum
-- required fields are title and source.branch.name.
local function create_body(args: Args): (any?, string?)
    local title = trim(args.title)
    if title == "" then return nil, "title is required for create_pull_request" end
    local source_branch = trim(args.source_branch)
    if source_branch == "" then return nil, "source_branch is required for create_pull_request" end

    local body: { [string]: any } = {
        title = title,
        source = { branch = { name = source_branch } },
    }
    local destination_branch = trim(args.destination_branch)
    if destination_branch ~= "" then
        body.destination = { branch = { name = destination_branch } }
    end
    local description = trim(args.description)
    if description ~= "" then body.description = description end
    if type(args.close_source_branch) == "boolean" then
        body.close_source_branch = args.close_source_branch
    end
    return body, nil
end

-- PUT body per the confirmed "Update a pull request" shape (partial —
-- "only open pull requests can be mutated", no state field exists on this
-- endpoint at all).
local function update_body(args: Args): (any?, string?)
    local body: { [string]: any } = {}
    local title = trim(args.title)
    if title ~= "" then body.title = title end
    local description = trim(args.description)
    if description ~= "" then body.description = description end
    local destination_branch = trim(args.destination_branch)
    if destination_branch ~= "" then
        body.destination = { branch = { name = destination_branch } }
    end
    if next(body) == nil then
        return nil, "at least one of title, description, or destination_branch is required for update_pull_request"
    end
    return body, nil
end

local function handler(args: Args): any
    args = type(args) == "table" and args or ({ action = "" } :: Args)
    local action = trim(args.action)
    if action == "" then return fail("action is required") end
    if not known_action(action) then return fail("unknown action '" .. tostring(action) .. "'") end

    local number: string? = nil
    local request_body: any = nil
    if action == "create_pull_request" then
        local berr
        request_body, berr = create_body(args)
        if berr then return fail(berr) end
    elseif action == "update_pull_request" then
        local nerr, berr
        number, nerr = require_number(args)
        if nerr then return fail(nerr) end
        request_body, berr = update_body(args)
        if berr then return fail(berr) end
    elseif action == "decline_pull_request" then
        local nerr
        number, nerr = require_number(args)
        if nerr then return fail(nerr) end
    else
        local nerr
        number, nerr = require_number(args)
        if nerr then return fail(nerr) end
        local comment_body = trim(args.body)
        if comment_body == "" then return fail("body is required for create_comment") end
        -- Confirmed live: a pull request comment's request body is
        -- { content: { raw: "..." } }.
        request_body = { content = { raw = comment_body } }
    end

    local tp = M._transport
    local resolved, rerr = tp.resolve(connection_id())
    if rerr or not resolved then return fail(rerr or "no connection") end
    local client, workspace, repo_slug = resolved.client, resolved.workspace, resolved.repo_slug
    if not client then return fail("no connection") end

    local result
    if action == "create_pull_request" then
        local data, err = client:post(repo_path(workspace, repo_slug, "/pullrequests"), request_body)
        result = { data = data, err = err }
    elseif action == "update_pull_request" then
        local data, err = client:put(repo_path(workspace, repo_slug, "/pullrequests/" .. (number :: string)), request_body)
        result = { data = data, err = err }
    elseif action == "decline_pull_request" then
        local data, err = client:post(repo_path(workspace, repo_slug, "/pullrequests/" .. (number :: string) .. "/decline"), nil)
        result = { data = data, err = err }
    else
        local data, err = client:post(repo_path(workspace, repo_slug, "/pullrequests/" .. (number :: string) .. "/comments"), request_body)
        result = { data = data, err = err }
    end

    if result.err then return fail(result.err.message or "request failed") end
    return encode(result.data)
end

M.handler = handler

return M
