-- Bitbucket Cloud pull-request fetch, pagination, normalization, and the
-- kickside.data:pullable envelope itself (M.pull / M.pull_keys).
--
-- The envelope shape below is now CONFIRMED against the real, unpacked
-- kickside/providers monorepo source (local paths, not fetched from
-- git.wippy.ai — see BUILD-NOTES.md "RESOLVED: kickside.data:pullable
-- envelope"):
--   providers-master\providers-master\github\src\source\pull_core.lua
--   providers-master\providers-master\atlassian\src\jira\source\pull_core.lua
-- It replaces the envelope previously inferred by analogy, which used to
-- live in source/pull.lua's header comment.
--
-- Item envelope: every item is wrapped as
--   { item_key, dedup_key, op = "upsert", source_version, occurred_at,
--     payload = <normalized item> }
-- Cursor: an opaque TABLE (never a bare string) — here { next_url = ... },
-- carrying Bitbucket's own literal `next` pagination URL (see the
-- pagination doc comment below). `next_cursor` is set on EVERY successful
-- response, has_more true or false — on exhaustion it resets to
-- { next_url = nil } (start over from page 1) so a scheduler can keep
-- polling forever, matching both real examples' reset-on-exhaustion
-- behavior. This connector does not filter continuation by
-- backfill_since/updated-since (no verified Bitbucket query filter for it
-- — see BUILD-NOTES.md); resetting to page 1 means a full rescan each
-- cycle, a real but disclosed inefficiency, not a silent gap.
--
-- Pagination mechanics (empirically verified 2026-09-02, see
-- BUILD-NOTES.md "Empirically-verified REST API pagination shapes"):
-- Bitbucket's list response body carries `{ values, pagelen, size, page,
-- next }`, where `next` is a complete, already-query-stringed absolute URL
-- to follow literally, or absent/nil when the list is exhausted. We reuse
-- that `next` URL verbatim as fetch_page/list_all's own opaque pagination
-- cursor — no separate cursor encoding needed at that layer; M.pull/
-- M.pull_keys below are what fold it into the table-shaped envelope cursor
-- Data Sync sees.

local ctx = require("ctx")
local data_error = require("data_error")
local transport = require("transport")
local types = require("types")

local M = {}

local DEFAULT_LIMIT = 50
local MAX_LIMIT = 100

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function config_value(config: any, key: string): string
    return trim(type(config) == "table" and config[key] or nil)
end

-- Bitbucket PR `state` -> normalized item `state`. SUPERSEDED collapses
-- onto "declined" — the closest normalized equivalent. This is a real,
-- deliberate information loss (a superseded PR is not the same thing as a
-- declined one), called out here and in BUILD-NOTES.md.
local function normalized_state(raw_state)
    return types.PR_STATE_MAP[raw_state] or "open"
end

local function item_key_of(workspace, repo_slug, id)
    return "bitbucket:" .. tostring(workspace) .. "/" .. tostring(repo_slug) .. ":pr:" .. tostring(id)
end

local function version_of(raw)
    return tostring(raw.updated_on or raw.created_on or raw.id or "")
end

-- Maps one raw Bitbucket pull request item onto the module's normalized
-- payload shape, then wraps it in the confirmed pullable item envelope.
-- Field mapping notes:
--   author         <- author.display_name
--   source_branch  <- source.branch.name
--   target_branch  <- destination.branch.name
--   created_at     <- created_on (note the _on vs _at naming)
--   updated_at     <- updated_on
--   merged_at      <- updated_on, ONLY when state == "MERGED" — Bitbucket's
--                     PR payload carries no distinct "merged at" timestamp
--                     in what was observed live (only updated_on and a
--                     nested merge_commit once merged); this is a
--                     documented approximation, not a silent guess.
--   source_url     <- links.html.href (renamed from this module's earlier
--                     `url` field to match the platform's own payload
--                     convention, confirmed in both real reference
--                     pull_core.lua files)
function M.normalize_item(raw, workspace, repo_slug)
    raw = type(raw) == "table" and raw or {}
    local source = type(raw.source) == "table" and raw.source or {}
    local source_branch = type(source.branch) == "table" and source.branch or {}
    local destination = type(raw.destination) == "table" and raw.destination or {}
    local dest_branch = type(destination.branch) == "table" and destination.branch or {}
    local author = type(raw.author) == "table" and raw.author or {}
    local links = type(raw.links) == "table" and raw.links or {}
    local html_link = type(links.html) == "table" and links.html or {}

    local merged_at = nil
    if raw.state == "MERGED" then merged_at = raw.updated_on end

    local id = raw.id ~= nil and tostring(raw.id) or ""
    local version = version_of(raw)
    local item_key = item_key_of(workspace, repo_slug, id)

    return {
        item_key = item_key,
        dedup_key = item_key .. ":" .. version,
        op = "upsert",
        source_version = version ~= "" and version or nil,
        occurred_at = version ~= "" and version or nil,
        payload = {
            id = id ~= "" and id or nil,
            title = raw.title,
            state = normalized_state(raw.state),
            author = author.display_name,
            source_branch = source_branch.name,
            target_branch = dest_branch.name,
            created_at = raw.created_on,
            updated_at = raw.updated_on,
            merged_at = merged_at,
            source_url = html_link.href,
            raw = raw,
        },
    }
end

-- Lightweight key-only projection for Data Sync reconcile (pull_keys) —
-- just the item_key/dedup_key pair the confirmed envelope requires, not
-- the full normalized item.
function M.normalize_key(raw, workspace, repo_slug)
    raw = type(raw) == "table" and raw or {}
    local id = raw.id ~= nil and tostring(raw.id) or ""
    local version = version_of(raw)
    local item_key = item_key_of(workspace, repo_slug, id)
    return {
        item_key = item_key,
        dedup_key = item_key .. ":" .. version,
    }
end

-- Builds the query params for the first page of a pull request listing.
-- `opts.state`, when set, must be one of OPEN/MERGED/DECLINED/SUPERSEDED
-- (Bitbucket's own values, not the normalized ones) — passed straight
-- through as Bitbucket's own `state` query param. Leaving it unset means
-- Bitbucket applies its own default, which returns OPEN pull requests only
-- (verified empirically, see BUILD-NOTES.md) — callers that want every PR
-- must page through each state explicitly or accept that default.
local function first_page_path(workspace, repo_slug)
    return string.format("/repositories/%s/%s/pullrequests", workspace, repo_slug)
end

local function first_page_query(opts)
    local query = { pagelen = opts.pagelen or 50 }
    if type(opts.state) == "string" and opts.state ~= "" then
        query.state = opts.state
    end
    return query
end

-- Fetches exactly one page. `cursor` is nil for the first page, or the
-- literal `next` URL returned by a previous call (see module doc comment).
-- `opts`: { state=, pagelen=, keys_only=bool }. Returns
-- ({ items, next_cursor, has_more }, nil) or (nil, data_error).
function M.fetch_page(client, workspace, repo_slug, cursor, opts)
    opts = type(opts) == "table" and opts or {}

    local data, err
    if cursor then
        data, err = client:get(cursor)
    else
        data, err = client:get(first_page_path(workspace, repo_slug), { query = first_page_query(opts) })
    end
    if err then return nil, err end

    local values = type(data) == "table" and data.values or {}
    local normalize = opts.keys_only and M.normalize_key or M.normalize_item
    local items = {}
    for i, raw in ipairs(values) do
        items[i] = normalize(raw, workspace, repo_slug)
    end

    local next_cursor = type(data) == "table" and data.next or nil
    return {
        items = items,
        next_cursor = next_cursor,
        has_more = next_cursor ~= nil,
    }, nil
end

-- Walks every page from `cursor` (nil = start) until exhausted or
-- `opts.max_pages` is reached (default 1000, a runaway-loop guard, not a
-- product limit). Used by tests and by any caller that wants the complete
-- set in one call; M.pull/M.pull_keys below use fetch_page directly since
-- the engine owns cursoring across separate pull() calls.
function M.list_all(client, workspace, repo_slug, cursor, opts)
    opts = type(opts) == "table" and opts or {}
    local max_pages = opts.max_pages or 1000

    local all_items = {}
    local page_cursor = cursor
    local pages = 0
    repeat
        local page, err = M.fetch_page(client, workspace, repo_slug, page_cursor, opts)
        if err then return nil, err end
        for _, item in ipairs(page.items) do
            all_items[#all_items + 1] = item
        end
        page_cursor = page.next_cursor
        pages = pages + 1
    until not page_cursor or pages >= max_pages

    return all_items, nil
end

-- Resolves everything a pull()/pull_keys() call needs from `req`/`deps`:
-- the target repository, a connected client, the clamped page limit, and
-- the unwrapped literal Bitbucket cursor. Returns (resolved, nil) or
-- (nil, envelope) where `envelope` is already a full pullable failure
-- response (data_error.invalid_config/data_error.connection), ready to
-- return directly from M.pull/M.pull_keys.
--
-- component_id resolution fallback chain (matching the real reference
-- pull_core.lua files exactly): deps.component_id -> ctx.get("component_id")
-- -> config.connection_id. The common case is covered by
-- source/_index.yaml's `context_required: [component_id]` on the pullable
-- contract binding (ctx.get succeeds); the config.connection_id fallback is
-- what the real production code does for robustness when Data Sync invokes
-- the source outside a fully-scoped context.
local function resolve(req, deps)
    req = type(req) == "table" and req or {}
    deps = type(deps) == "table" and deps or {}
    local tp = deps.transport or transport
    local config = type(req.config) == "table" and req.config or {}

    local workspace = config_value(config, "workspace")
    local repo_slug = config_value(config, "repo_slug")
    if workspace == "" then return nil, data_error.invalid_config("config.workspace is required") end
    if repo_slug == "" then return nil, data_error.invalid_config("config.repo_slug is required") end

    local component_id = trim(deps.component_id)
    if component_id == "" then component_id = trim(ctx.get("component_id")) end
    if component_id == "" then component_id = config_value(config, "connection_id") end

    local client, cerr = tp.for_component(component_id)
    if cerr or not client then return nil, data_error.connection(tostring(cerr or "no connection")) end

    -- req.limit (the engine's own page-size hint) takes precedence; falls
    -- back to this port's own config.pagelen field, then the module
    -- default. Preserves config.pagelen's pre-existing meaning (see
    -- source/_index.yaml's repo_pulls.config_schema.pagelen) now that page
    -- sizing is also reachable via the confirmed req.limit envelope field.
    local limit = tonumber(req.limit) or tonumber(config.pagelen) or DEFAULT_LIMIT
    if limit < 1 then limit = 1 end
    if limit > MAX_LIMIT then limit = MAX_LIMIT end

    local cursor = type(req.cursor) == "table" and req.cursor or {}
    local next_url = type(cursor.next_url) == "string" and cursor.next_url or nil

    return {
        client = client,
        workspace = workspace,
        repo_slug = repo_slug,
        limit = limit,
        next_url = next_url,
        state = config_value(config, "state"),
    }, nil
end

-- kickside.data:pullable.pull. See the module doc comment above for the
-- confirmed envelope shape.
function M.pull(req, deps)
    local r, err = resolve(req, deps)
    if err then return err end

    local page, perr = M.fetch_page(r.client, r.workspace, r.repo_slug, r.next_url, {
        state = r.state ~= "" and r.state or nil,
        pagelen = r.limit,
    })
    if perr then return data_error.from_result(perr, "list Bitbucket pull requests") end

    return {
        success = true,
        items = page.items,
        next_cursor = page.has_more and { next_url = page.next_cursor } or { next_url = nil },
        has_more = page.has_more,
        coverage = { mode = "delta" },
    }
end

-- Keys-only listing used by Data Sync reconcile. Wired to the automation
-- port's `reconcile.pull_keys` field (source/_index.yaml), not bound as a
-- second kickside.data:pullable method — that contract accepts exactly one
-- bound method, `pull` (confirmed live against the real contract
-- definition, see BUILD-NOTES.md).
function M.pull_keys(req, deps)
    local r, err = resolve(req, deps)
    if err then return err end

    local page, perr = M.fetch_page(r.client, r.workspace, r.repo_slug, r.next_url, {
        state = r.state ~= "" and r.state or nil,
        pagelen = r.limit,
        keys_only = true,
    })
    if perr then return data_error.from_result(perr, "list Bitbucket pull requests") end

    return {
        success = true,
        keys = page.items,
        next_cursor = page.has_more and { next_url = page.next_cursor } or { next_url = nil },
        has_more = page.has_more,
    }
end

return M
