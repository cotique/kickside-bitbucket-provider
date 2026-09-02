local test = require("test")
local pull_core = require("pull_core")
local conformance = require("conformance")

-- A plain Lua test double for client:api's :get(path_or_url, opts) interface
-- (per BUILD-NOTES.md: "a plain Lua test double ... that returns canned
-- paginated fixture data so pull_core's pagination logic gets exercised
-- without a real network call"). Each call consumes one scripted response in
-- order and records what it was called with, so tests can assert pull_core
-- followed the literal `next` URL rather than reconstructing pagination
-- itself.
local function new_fake_client(scripted_responses)
    local calls = ({}) :: { any }
    local client = {}
    function client:get(path_or_url, opts)
        calls[#calls + 1] = { path = path_or_url, opts = opts }
        local next_response = table.remove(scripted_responses, 1)
        if not next_response then
            return nil, { code = "test_exhausted", message = "fake_client ran out of scripted responses", retriable = false, scope = "provider" }
        end
        return next_response, nil
    end
    return { client = client, calls = calls }
end

-- deps.transport double for pull_core.pull/pull_keys — mirrors the real
-- client:transport module's .for_component(component_id) -> (client, err)
-- shape. component_id == "bad" simulates a revoked/unresolvable connection,
-- matching the pattern used by the real reference pull_core_test.lua files
-- (github's and jira's fake .connect()).
local function new_fake_transport(scripted_responses)
    local fc = new_fake_client(scripted_responses)
    local seen_component_ids = {}
    return {
        for_component = function(component_id)
            seen_component_ids[#seen_component_ids + 1] = component_id
            if component_id == "bad" then return nil, "revoked" end
            return fc.client, nil
        end,
        seen_component_ids = seen_component_ids,
        calls = fc.calls,
    }
end

-- One realistic Bitbucket pull request item per the empirically-verified
-- payload shape captured in BUILD-NOTES.md.
local function raw_pr(overrides)
    local pr = {
        id = 42,
        title = "Fix the thing",
        description = "Some description",
        state = "OPEN",
        author = { display_name = "Ada Lovelace" },
        source = { branch = { name = "feature/fix-the-thing" } },
        destination = { branch = { name = "main" } },
        created_on = "2026-01-01T00:00:00.000000+00:00",
        updated_on = "2026-01-02T00:00:00.000000+00:00",
        links = { html = { href = "https://bitbucket.org/acme/my-repo/pull-requests/42" } },
    }
    for k, v in pairs(overrides or {}) do pr[k] = v end
    return pr
end

local function define_tests()
    test.describe("cotique.bitbucket_provider.source.pull_core item normalization", function()
        test.it("wraps every field into the confirmed pullable item envelope from a realistic fixture", function()
            local item = pull_core.normalize_item(raw_pr({}), "acme", "my-repo")
            test.eq(item.item_key, "bitbucket:acme/my-repo:pr:42")
            test.eq(item.dedup_key, "bitbucket:acme/my-repo:pr:42:2026-01-02T00:00:00.000000+00:00")
            test.eq(item.op, "upsert")
            test.eq(item.source_version, "2026-01-02T00:00:00.000000+00:00")
            test.eq(item.occurred_at, "2026-01-02T00:00:00.000000+00:00")
            test.eq(item.payload.id, "42")
            test.eq(item.payload.title, "Fix the thing")
            test.eq(item.payload.state, "open")
            test.eq(item.payload.author, "Ada Lovelace")
            test.eq(item.payload.source_branch, "feature/fix-the-thing")
            test.eq(item.payload.target_branch, "main")
            test.eq(item.payload.created_at, "2026-01-01T00:00:00.000000+00:00")
            test.eq(item.payload.updated_at, "2026-01-02T00:00:00.000000+00:00")
            test.is_nil(item.payload.merged_at, "merged_at must be nil for a non-merged PR")
            test.eq(item.payload.source_url, "https://bitbucket.org/acme/my-repo/pull-requests/42")
            test.not_nil(item.payload.raw)
            test.eq(item.payload.raw.id, 42)
        end)

        test.it("maps MERGED state and sets merged_at to updated_on only when merged", function()
            local item = pull_core.normalize_item(raw_pr({ state = "MERGED", updated_on = "2026-01-05T00:00:00.000000+00:00" }), "acme", "my-repo")
            test.eq(item.payload.state, "merged")
            test.eq(item.payload.merged_at, "2026-01-05T00:00:00.000000+00:00")
        end)

        test.it("maps DECLINED state and leaves merged_at nil", function()
            local item = pull_core.normalize_item(raw_pr({ state = "DECLINED" }), "acme", "my-repo")
            test.eq(item.payload.state, "declined")
            test.is_nil(item.payload.merged_at)
        end)

        test.it("collapses SUPERSEDED onto declined (documented information loss)", function()
            local item = pull_core.normalize_item(raw_pr({ state = "SUPERSEDED" }), "acme", "my-repo")
            test.eq(item.payload.state, "declined")
            test.is_nil(item.payload.merged_at)
        end)

        test.it("builds a lightweight { item_key, dedup_key } projection for pull_keys", function()
            local key = pull_core.normalize_key(raw_pr({ id = 7, updated_on = "2026-02-01T00:00:00.000000+00:00" }), "acme", "my-repo")
            test.eq(key.item_key, "bitbucket:acme/my-repo:pr:7")
            test.eq(key.dedup_key, "bitbucket:acme/my-repo:pr:7:2026-02-01T00:00:00.000000+00:00")
            test.is_nil(key.payload, "pull_keys projection must not carry the full normalized item")
            test.is_nil(key.op, "pull_keys projection must not carry the full normalized item")
        end)
    end)

    test.describe("cotique.bitbucket_provider.source.pull_core pagination", function()
        test.it("requests the first page at the expected path with query params", function()
            local fc = new_fake_client({
                { values = { raw_pr({ id = 1 }) }, pagelen = 50, size = 1, page = 1 },
            })
            local client, calls = fc.client, fc.calls

            local page, err = pull_core.fetch_page(client, "acme", "my-repo", nil, { pagelen = 50 })
            test.is_nil(err)
            test.eq(#calls, 1)
            test.eq(calls[1].path, "/repositories/acme/my-repo/pullrequests")
            test.eq(calls[1].opts.query.pagelen, 50)
            test.eq(#page.items, 1)
            test.eq(page.items[1].payload.id, "1")
            test.is_nil(page.next_cursor)
            test.eq(page.has_more, false)
        end)

        test.it("passes an explicit state filter through as Bitbucket's own state query param", function()
            local fc = new_fake_client({
                { values = {}, pagelen = 50, size = 0, page = 1 },
            })
            local client, calls = fc.client, fc.calls
            pull_core.fetch_page(client, "acme", "my-repo", nil, { state = "MERGED" })
            test.eq(calls[1].opts.query.state, "MERGED")
        end)

        test.it("follows the literal next URL for the second page instead of reconstructing it", function()
            local next_url = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?pagelen=2&page=2"
            local fc = new_fake_client({
                { values = { raw_pr({ id = 1 }) }, pagelen = 2, size = 3, page = 1, next = next_url },
                { values = { raw_pr({ id = 2 }) }, pagelen = 2, size = 3, page = 2 },
            })
            local client, calls = fc.client, fc.calls

            local page1, err1 = pull_core.fetch_page(client, "acme", "my-repo", nil, { pagelen = 2 })
            test.is_nil(err1)
            test.eq(page1.next_cursor, next_url)
            test.is_true(page1.has_more)

            local page2, err2 = pull_core.fetch_page(client, "acme", "my-repo", page1.next_cursor, { pagelen = 2 })
            test.is_nil(err2)
            test.eq(calls[2].path, next_url, "must follow the literal next URL, not a reconstructed one")
            test.eq(page2.items[1].payload.id, "2")
            test.is_nil(page2.next_cursor)
            test.eq(page2.has_more, false)
        end)

        test.it("list_all walks every page and stops when next is exhausted", function()
            local url2 = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=2"
            local url3 = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=3"
            local fc = new_fake_client({
                { values = { raw_pr({ id = 1 }) }, next = url2 },
                { values = { raw_pr({ id = 2 }) }, next = url3 },
                { values = { raw_pr({ id = 3 }) } },
            })
            local client, calls = fc.client, fc.calls

            local items, err = pull_core.list_all(client, "acme", "my-repo", nil, {})
            test.is_nil(err)
            test.eq(#items, 3)
            test.eq(items[1].payload.id, "1")
            test.eq(items[2].payload.id, "2")
            test.eq(items[3].payload.id, "3")
            test.eq(#calls, 3, "must stop calling once a page has no next")
        end)

        test.it("list_all respects the max_pages runaway guard", function()
            local url = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=next"
            local fc = new_fake_client({
                { values = { raw_pr({ id = 1 }) }, next = url },
                { values = { raw_pr({ id = 2 }) }, next = url },
                { values = { raw_pr({ id = 3 }) }, next = url },
                { values = { raw_pr({ id = 4 }) }, next = url },
            })
            local client, calls = fc.client, fc.calls

            local items, err = pull_core.list_all(client, "acme", "my-repo", nil, { max_pages = 2 })
            test.is_nil(err)
            test.eq(#calls, 2, "must stop at max_pages even though the server keeps returning next")
            test.eq(#items, 2)
        end)

        test.it("propagates a client error instead of looping", function()
            local client = new_fake_client({}).client
            local page, err = pull_core.fetch_page(client, "acme", "my-repo", nil, {})
            test.is_nil(page)
            test.not_nil(err)
            test.eq(err.code, "test_exhausted")
        end)

        test.it("uses the key-only projection when keys_only is set", function()
            local client = new_fake_client({
                { values = { raw_pr({ id = 9 }) } },
            }).client
            local page, err = pull_core.fetch_page(client, "acme", "my-repo", nil, { keys_only = true })
            test.is_nil(err)
            test.eq(page.items[1].item_key, "bitbucket:acme/my-repo:pr:9")
            test.is_nil(page.items[1].payload, "keys_only page must carry only the lightweight { item_key, dedup_key } projection")
        end)
    end)

    test.describe("cotique.bitbucket_provider.source.pull_core pullable envelope (pull/pull_keys)", function()
        test.it("returns a table cursor and reaches has_more with a non-empty next_cursor.next_url", function()
            local tp = new_fake_transport({
                { values = { raw_pr({ id = 1 }) }, next = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=2" },
            })
            local page = pull_core.pull({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn1" }, limit = 2 }, { transport = tp })
            test.eq(page.success, true)
            test.eq(#page.items, 1)
            test.eq(page.items[1].item_key, "bitbucket:acme/my-repo:pr:1")
            test.eq(page.items[1].op, "upsert")
            test.eq(page.has_more, true)
            test.eq(type(page.next_cursor), "table")
            test.eq(page.next_cursor.next_url, "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=2")
            test.eq(page.coverage.mode, "delta")
        end)

        test.it("resets next_cursor to a fresh { next_url = nil } position on exhaustion, not nil", function()
            local tp = new_fake_transport({
                { values = { raw_pr({ id = 1 }) } },
            })
            local page = pull_core.pull({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn1" } }, { transport = tp })
            test.eq(page.success, true)
            test.eq(page.has_more, false)
            test.not_nil(page.next_cursor, "next_cursor must be set on every successful response, even when exhausted")
            test.is_nil(page.next_cursor.next_url)
        end)

        test.it("follows a returned table cursor's next_url into the next page's request", function()
            local url2 = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=2"
            local tp = new_fake_transport({
                { values = { raw_pr({ id = 1 }) }, next = url2 },
                { values = { raw_pr({ id = 2 }) } },
            })
            local config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn1" }
            local first = pull_core.pull({ config = config }, { transport = tp })
            local second = pull_core.pull({ cursor = first.next_cursor, config = config }, { transport = tp })
            test.eq(tp.calls[2].path, url2)
            test.eq(second.items[1].payload.id, "2")
            test.eq(second.has_more, false)
        end)

        test.it("reports invalid config loudly when workspace or repo_slug is missing", function()
            local tp = new_fake_transport({})
            local page = pull_core.pull({ config = { repo_slug = "my-repo" } }, { transport = tp })
            test.eq(page.success, false)
            test.eq(page.error.code, "invalid_config")

            page = pull_core.pull({ config = { workspace = "acme" } }, { transport = tp })
            test.eq(page.success, false)
            test.eq(page.error.code, "invalid_config")
        end)

        test.it("classifies a connection failure as auth_expired", function()
            local tp = new_fake_transport({})
            local page = pull_core.pull({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "bad" } }, { transport = tp })
            test.eq(page.success, false)
            test.eq(page.error.code, "auth_expired")
            test.eq(page.error.scope, "connection")
        end)

        test.it("resolves component_id via deps.component_id before falling back to config.connection_id", function()
            local tp = new_fake_transport({ { values = {} } })
            pull_core.pull({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn-from-config" } }, { transport = tp, component_id = "conn-from-deps" })
            test.eq(tp.seen_component_ids[1], "conn-from-deps")
        end)

        test.it("falls back to config.connection_id when deps.component_id is absent", function()
            local tp = new_fake_transport({ { values = {} } })
            pull_core.pull({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn-from-config" } }, { transport = tp })
            test.eq(tp.seen_component_ids[1], "conn-from-config")
        end)

        test.it("emits keys-only pages for Data Sync reconcile", function()
            local tp = new_fake_transport({
                { values = { raw_pr({ id = 1 }), raw_pr({ id = 2 }) } },
            })
            local page = pull_core.pull_keys({ config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn1" } }, { transport = tp })
            test.eq(page.success, true)
            test.is_nil(page.items)
            test.eq(#page.keys, 2)
            test.eq(page.keys[1].item_key, "bitbucket:acme/my-repo:pr:1")
            test.not_nil(page.keys[1].dedup_key)
        end)
    end)

    test.describe("cotique.bitbucket_provider.source.pull_core conformance", function()
        -- Deterministic-by-URL fake, safe to reuse across every call the kit
        -- makes (the main pagination loop, the one-off failure-path call,
        -- and the pull_keys call) without needing separate queue state per
        -- call: the first (relative) page path always returns page 1, and
        -- the literal PAGE_2_URL always returns page 2 (exhausted).
        local PAGE_2_URL = "https://api.bitbucket.org/2.0/repositories/acme/my-repo/pullrequests?page=2"

        local function conformance_transport()
            local client = {}
            function client:get(path_or_url)
                if path_or_url == PAGE_2_URL then
                    return { values = { raw_pr({ id = 3, updated_on = "2026-01-03T00:00:00.000000+00:00" }) } }, nil
                end
                return {
                    values = {
                        raw_pr({ id = 1, updated_on = "2026-01-01T00:00:00.000000+00:00" }),
                        raw_pr({ id = 2, updated_on = "2026-01-02T00:00:00.000000+00:00" }),
                    },
                    next = PAGE_2_URL,
                }, nil
            end
            return {
                for_component = function(component_id)
                    if component_id == "bad" then return nil, "revoked" end
                    return client, nil
                end,
            }
        end

        test.it("passes the pullable conformance kit offline", function()
            local tp = conformance_transport()
            local result = conformance.run({
                pull = function(req) return pull_core.pull(req, { transport = tp }) end,
                pull_keys = function(req) return pull_core.pull_keys(req, { transport = tp }) end,
                config = { workspace = "acme", repo_slug = "my-repo", connection_id = "conn1" },
                failure_config = { workspace = "acme", repo_slug = "my-repo", connection_id = "bad" },
                backfill_since = {
                    mode = "ignored",
                    reason = "No verified Bitbucket Cloud query filter for updated-since pull request listing exists in this connector yet (see BUILD-NOTES.md) — config.state is the only supported server-side filter today.",
                },
                limit = 2,
                max_pages = 5,
            })
            test.eq(result.success, true, conformance.format_failures(result))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
