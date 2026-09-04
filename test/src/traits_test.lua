-- traits/read_tool.lua + traits/write_tool.lua handler logic, plus the
-- traits/_index.yaml registry-shape assertions — mirrors
-- kickside.github.traits:traits_test.lua's own test shape and coverage,
-- adapted to this module's client/transport.resolve(connection_id) ->
-- { client, workspace, repo_slug } seam instead of GitHub's
-- transport.connect(component_id) -> conn seam. Lives here, not colocated
-- next to src/traits/*.lua — see client/_index.yaml's note on why this
-- module's colocated logic tests live in the standalone harness.

local test = require("test")
local json = require("json")
local registry = require("registry")
local read_tool = require("read_tool")
local write_tool = require("write_tool")

local READ_TOOL = "cotique.bitbucket.traits:read_tool"
local WRITE_TOOL = "cotique.bitbucket.traits:write_tool"

local function get_entry(id)
    local entries, err = registry.find({ [".id"] = id })
    test.is_nil(err)
    test.not_nil(entries, id .. " lookup failed")
    test.eq(#entries, 1, id .. " should resolve once")
    return entries[1]
end

-- Defensive against either registry.find() shape this platform has been
-- observed to return (confirmed inconsistency, see this module's own
-- wiring_test.lua): meta/custom fields sometimes come back directly on the
-- entry, sometimes nested under entry.data.
local function meta_of(entry_or_id)
    local entry = type(entry_or_id) == "string" and get_entry(entry_or_id) or entry_or_id
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

local function decode_schema(entry)
    local meta = meta_of(entry)
    test.not_nil(meta, entry.id .. " missing meta")
    test.eq(meta.type, "tool")
    local schema, err = json.decode(tostring(meta.input_schema or ""))
    test.is_nil(err)
    test.eq(schema.type, "object")
    test.eq(schema.additionalProperties, false)
    return schema
end

local function enum_contains(enum, value)
    for _, item in ipairs(enum or {}) do
        if item == value then return true end
    end
    return false
end

-- Identity passthrough: read_tool_lib/write_tool_lib's own local encode()
-- calls M._output.redact(data) then json.encode()s the result itself (see
-- their file comments — client:output has no M.encode(data, max) helper),
-- so the fake here only needs to stand in for redact, not encode.
local fake_output = {
    redact = function(data)
        return data
    end,
}

local function with_tool(tool, fake_transport, fake_pull_core, fn)
    local old_transport, old_output, old_pull_core = tool._transport, tool._output, tool._pull_core
    tool._transport = fake_transport
    tool._output = fake_output
    if fake_pull_core then tool._pull_core = fake_pull_core end
    local ok, err = pcall(fn)
    tool._transport, tool._output = old_transport, old_output
    if old_pull_core then tool._pull_core = old_pull_core end
    if not ok then error(err) end
end

local function resolve_ok(client)
    return {
        resolve = function()
            return { client = client, workspace = "acme", repo_slug = "my-repo" }, nil
        end,
    }
end

local function resolve_should_not_be_called()
    return {
        resolve = function()
            error("resolve should not be called for invalid args")
        end,
    }
end

local function define_tests()
    test.describe("Bitbucket trait schemas", function()
        test.it("declares public context-configurable capabilities", function()
            for _, id in ipairs({
                "cotique.bitbucket.traits:reader",
                "cotique.bitbucket.traits:writer",
                "cotique.bitbucket.traits:manager",
            }) do
                local meta = meta_of(id)
                test.eq(meta.type, "agent.trait")
                test.is_true(meta.public)
                test.eq(meta.web_component, "kickside-connection-trait-picker")
                test.eq(meta.provider, "bitbucket")
                test.eq(meta.context_schema.type, "object")
                test.not_nil(meta.context_schema.properties.connection_id)
                test.eq(meta.context_schema.additionalProperties, false)
            end
        end)

        test.it("manager grants both read and write tools and states the write restraint", function()
            local entry = data_of(get_entry("cotique.bitbucket.traits:manager"))
            test.eq(entry.tools[1], READ_TOOL)
            test.eq(entry.tools[2], WRITE_TOOL)
            local prompt = tostring(entry.prompt or "")
            test.ok(prompt:find("Do not ask the user"))
            test.ok(prompt:find("Do not merge, approve, delete"))
        end)

        test.it("writer states it never merges, approves, or deletes anything", function()
            local entry = data_of(get_entry("cotique.bitbucket.traits:writer"))
            local prompt = tostring(entry.prompt or "")
            test.ok(prompt:find("never merges, approves, or deletes"))
        end)

        test.it("publishes read + write tools with complete action enums", function()
            local rt = get_entry(READ_TOOL)
            local wt = get_entry(WRITE_TOOL)
            local read_enum = decode_schema(rt).properties.action.enum
            local write_enum = decode_schema(wt).properties.action.enum
            test.is_true(enum_contains(meta_of(rt).tags, "bitbucket"))
            test.is_true(enum_contains(meta_of(rt).tags, "read-only"))
            test.is_true(enum_contains(meta_of(wt).tags, "bitbucket"))
            test.is_true(enum_contains(meta_of(wt).tags, "write"))
            for _, action in ipairs({ "get_repo", "list_pull_requests", "get_pull_request", "list_pull_request_comments" }) do
                test.is_true(enum_contains(read_enum, action), "missing read action " .. action)
            end
            for _, action in ipairs({ "create_pull_request", "update_pull_request", "decline_pull_request", "create_comment" }) do
                test.is_true(enum_contains(write_enum, action), "missing write action " .. action)
            end
        end)

        test.it("declares required_scopes including state.write on the write tool only", function()
            local rt_scopes = meta_of(get_entry(READ_TOOL)).mcp.required_scopes
            local wt_scopes = meta_of(get_entry(WRITE_TOOL)).mcp.required_scopes
            test.eq(rt_scopes[1], "state.read")
            test.eq(#rt_scopes, 1)
            local has_write = false
            for _, s in ipairs(wt_scopes) do if s == "state.write" then has_write = true end end
            test.is_true(has_write, "write tool must require state.write")
        end)

        test.it("keeps connection selection and repository identity out of model-facing schemas", function()
            for _, id in ipairs({ READ_TOOL, WRITE_TOOL }) do
                local schema_text = tostring(meta_of(get_entry(id)).input_schema or "")
                test.is_nil(schema_text:find("component_id", 1, true), id .. " exposes component_id")
                test.is_nil(schema_text:find("connection_id", 1, true), id .. " exposes connection_id")
                test.is_nil(schema_text:find("\"workspace\"", 1, true), id .. " exposes workspace")
                test.is_nil(schema_text:find("repo_slug", 1, true), id .. " exposes repo_slug")
            end
        end)
    end)

    test.describe("BitbucketRead tool", function()
        test.it("validates action and pull request number before resolving a connection", function()
            with_tool(read_tool, resolve_should_not_be_called(), nil, function()
                test.ok(read_tool.handler({}):find("action is required"))
                test.ok(read_tool.handler({ action = "nope" }):find("unknown action"))
                test.ok(read_tool.handler({ action = "get_pull_request" }):find("number is required"))
                test.ok(read_tool.handler({ action = "list_pull_request_comments" }):find("number is required"))
                test.ok(read_tool.handler({ action = "list_pull_requests", state = "bogus" }):find("state must be"))
            end)
        end)

        test.it("dispatches list_pull_requests to pull_core.fetch_page with clamped limit and state", function()
            local seen = nil
            local fake_pc = {
                fetch_page = function(client, workspace, repo_slug, cursor, opts)
                    seen = { workspace = workspace, repo_slug = repo_slug, cursor = cursor, opts = opts }
                    return { items = { { item_key = "bitbucket:acme/my-repo:pr:1" } }, next_cursor = nil, has_more = false }, nil
                end,
            }
            with_tool(read_tool, resolve_ok({}), fake_pc, function()
                local decoded = json.decode(tostring(read_tool.handler({
                    action = "list_pull_requests",
                    state = "MERGED",
                    limit = 999,
                })))
                test.eq(#decoded.items, 1)
                test.eq(seen.workspace, "acme")
                test.eq(seen.repo_slug, "my-repo")
                test.eq(seen.opts.state, "MERGED")
                test.eq(seen.opts.pagelen, 100)
                test.is_nil(seen.cursor)
            end)
        end)

        test.it("routes get_repo, get_pull_request, and list_pull_request_comments to the expected client calls", function()
            local seen = {}
            local client = {}
            function client:get(path_or_url, opts)
                seen[#seen + 1] = { path = path_or_url, opts = opts }
                if path_or_url:find("/comments", 1, true) then
                    return { values = { { id = 1 } }, next = "https://api.bitbucket.org/2.0/next-page" }, nil
                end
                if path_or_url:find("/pullrequests/", 1, true) then
                    return { id = 9, title = "Fix", state = "OPEN" }, nil
                end
                return { uuid = "{repo}" }, nil
            end
            local fake_pc = {
                normalize_item = function(raw, workspace, repo_slug)
                    return { item_key = "bitbucket:" .. workspace .. "/" .. repo_slug .. ":pr:" .. tostring(raw.id), payload = { title = raw.title } }
                end,
            }
            with_tool(read_tool, resolve_ok(client), fake_pc, function()
                local repo = json.decode(tostring(read_tool.handler({ action = "get_repo" })))
                test.eq(repo.uuid, "{repo}")
                test.eq(seen[1].path, "/repositories/acme/my-repo")

                local pr = json.decode(tostring(read_tool.handler({ action = "get_pull_request", number = "9" })))
                test.eq(pr.item_key, "bitbucket:acme/my-repo:pr:9")
                test.eq(seen[2].path, "/repositories/acme/my-repo/pullrequests/9")

                local comments = json.decode(tostring(read_tool.handler({ action = "list_pull_request_comments", number = "9" })))
                test.eq(#comments.values, 1)
                test.is_true(comments.has_more)
                test.eq(comments.next_cursor, "https://api.bitbucket.org/2.0/next-page")
                test.eq(seen[3].path, "/repositories/acme/my-repo/pullrequests/9/comments")
            end)
        end)

        test.it("follows a supplied cursor for list_pull_request_comments instead of the first-page path", function()
            local seen = nil
            local client = {}
            function client:get(path_or_url)
                seen = path_or_url
                return { values = {} }, nil
            end
            with_tool(read_tool, resolve_ok(client), {}, function()
                read_tool.handler({ action = "list_pull_request_comments", number = "9", cursor = "https://api.bitbucket.org/2.0/next-page" })
                test.eq(seen, "https://api.bitbucket.org/2.0/next-page")
            end)
        end)

        test.it("surfaces connection and API errors", function()
            with_tool(read_tool, { resolve = function() return nil, "no Bitbucket connection selected" end }, nil, function()
                test.ok(read_tool.handler({ action = "get_repo" }):find("no Bitbucket connection selected"))
            end)
            local client = {}
            function client:get() return nil, { code = "permission_denied", message = "forbidden" } end
            with_tool(read_tool, resolve_ok(client), {}, function()
                test.ok(read_tool.handler({ action = "get_repo" }):find("forbidden"))
            end)
        end)
    end)

    test.describe("BitbucketWrite tool", function()
        test.it("validates write arguments before resolving a connection", function()
            with_tool(write_tool, resolve_should_not_be_called(), nil, function()
                test.ok(write_tool.handler({}):find("action is required"))
                test.ok(write_tool.handler({ action = "merge_pull_request" }):find("unknown action"))
                test.ok(write_tool.handler({ action = "create_pull_request" }):find("title is required"))
                test.ok(write_tool.handler({ action = "create_pull_request", title = "T" }):find("source_branch is required"))
                test.ok(write_tool.handler({ action = "update_pull_request" }):find("number is required"))
                test.ok(write_tool.handler({ action = "update_pull_request", number = "1" }):find("at least one of"))
                test.ok(write_tool.handler({ action = "decline_pull_request" }):find("number is required"))
                test.ok(write_tool.handler({ action = "create_comment", number = "1" }):find("body is required"))
            end)
        end)

        test.it("creates a pull request with the confirmed request shape", function()
            local seen = nil
            local client = {}
            function client:post(path_or_url, body)
                seen = { path = path_or_url, body = body }
                return { id = 42, state = "OPEN" }, nil
            end
            with_tool(write_tool, resolve_ok(client), nil, function()
                local decoded = json.decode(tostring(write_tool.handler({
                    action = "create_pull_request",
                    title = "My Title",
                    source_branch = "feature/x",
                    destination_branch = "main",
                    description = "desc",
                    close_source_branch = true,
                })))
                test.eq(decoded.id, 42)
                test.eq(seen.path, "/repositories/acme/my-repo/pullrequests")
                test.eq(seen.body.title, "My Title")
                test.eq(seen.body.source.branch.name, "feature/x")
                test.eq(seen.body.destination.branch.name, "main")
                test.eq(seen.body.description, "desc")
                test.is_true(seen.body.close_source_branch)
            end)
        end)

        test.it("updates a pull request with a partial body and never sends a state field", function()
            local seen = nil
            local client = {}
            function client:put(path_or_url, body)
                seen = { path = path_or_url, body = body }
                return { id = 7, title = "New title" }, nil
            end
            with_tool(write_tool, resolve_ok(client), nil, function()
                local decoded = json.decode(tostring(write_tool.handler({
                    action = "update_pull_request",
                    number = "7",
                    title = "New title",
                })))
                test.eq(decoded.id, 7)
                test.eq(seen.path, "/repositories/acme/my-repo/pullrequests/7")
                test.eq(seen.body.title, "New title")
                test.is_nil(seen.body.state, "update_pull_request must never send a state field")
                test.is_nil(seen.body.description)
            end)
        end)

        test.it("declines a pull request with no request body via the dedicated decline endpoint", function()
            local seen = nil
            local client = {}
            function client:post(path_or_url, body)
                seen = { path = path_or_url, body = body }
                return { id = 7, state = "DECLINED" }, nil
            end
            with_tool(write_tool, resolve_ok(client), nil, function()
                local decoded = json.decode(tostring(write_tool.handler({ action = "decline_pull_request", number = "7" })))
                test.eq(decoded.state, "DECLINED")
                test.eq(seen.path, "/repositories/acme/my-repo/pullrequests/7/decline")
                test.is_nil(seen.body, "decline must send no request body")
            end)
        end)

        test.it("creates a comment with the confirmed { content: { raw } } shape", function()
            local seen = nil
            local client = {}
            function client:post(path_or_url, body)
                seen = { path = path_or_url, body = body }
                return { id = 2154, content = { raw = body.content.raw } }, nil
            end
            with_tool(write_tool, resolve_ok(client), nil, function()
                local decoded = json.decode(tostring(write_tool.handler({
                    action = "create_comment",
                    number = "7",
                    body = "done",
                })))
                test.eq(decoded.content.raw, "done")
                test.eq(seen.path, "/repositories/acme/my-repo/pullrequests/7/comments")
                test.eq(seen.body.content.raw, "done")
            end)
        end)

        test.it("surfaces write API errors, including a permission_denied mapping to a missing write scope", function()
            local client = {}
            function client:post() return nil, { code = "permission_denied", message = "access token lacks Pull requests: Write scope" } end
            with_tool(write_tool, resolve_ok(client), nil, function()
                test.ok(write_tool.handler({
                    action = "create_pull_request",
                    title = "T",
                    source_branch = "feature/x",
                }):find("Pull requests: Write"))
            end)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
