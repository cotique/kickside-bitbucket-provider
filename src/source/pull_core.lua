-- Bitbucket Cloud pull-request fetch, pagination, and normalization. This is
-- the fully-verified, independently-tested layer: it takes an already-built
-- client:api instance (or, in tests, a plain Lua fake satisfying the same
-- :get(path, opts) -> (decoded_json, data_error) interface) and does not
-- depend on the guessed kickside.data:pullable request/response envelope —
-- see source/pull.lua for that boundary and BUILD-NOTES.md for why it's
-- kept separate.
--
-- Pagination mechanics (empirically verified 2026-09-02, see
-- BUILD-NOTES.md "Empirically-verified REST API pagination shapes"):
-- Bitbucket's list response body carries `{ values, pagelen, size, page,
-- next }`, where `next` is a complete, already-query-stringed absolute URL
-- to follow literally, or absent/nil when the list is exhausted. We reuse
-- that `next` URL verbatim as this module's own opaque pagination cursor —
-- no separate cursor encoding needed.

local types = require("types")

local M = {}

-- Bitbucket PR `state` -> normalized item `state`. SUPERSEDED collapses
-- onto "declined" — the closest normalized equivalent. This is a real,
-- deliberate information loss (a superseded PR is not the same thing as a
-- declined one), called out here and in BUILD-NOTES.md.
local function normalized_state(raw_state)
    return types.PR_STATE_MAP[raw_state] or "open"
end

-- Maps one raw Bitbucket pull request item onto the module's normalized
-- item shape (see the shared brief's "Normalized item shape" section).
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
--   url            <- links.html.href
function M.normalize_item(raw)
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

    return {
        id = raw.id ~= nil and tostring(raw.id) or nil,
        title = raw.title,
        state = normalized_state(raw.state),
        author = author.display_name,
        source_branch = source_branch.name,
        target_branch = dest_branch.name,
        created_at = raw.created_on,
        updated_at = raw.updated_on,
        merged_at = merged_at,
        url = html_link.href,
        raw = raw,
    }
end

-- Lightweight key-only projection for Data Sync reconcile (pull_keys), not
-- the full normalized item.
function M.normalize_key(raw)
    raw = type(raw) == "table" and raw or {}
    return {
        id = raw.id ~= nil and tostring(raw.id) or nil,
        updated_at = raw.updated_on,
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
        items[i] = normalize(raw)
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
-- set in one call; the pullable wrappers in pull.lua use fetch_page
-- directly since the engine owns cursoring across separate pull() calls.
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

return M
