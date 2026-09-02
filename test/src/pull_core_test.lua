local test = require("test")
local pull_core = require("pull_core")

-- A plain Lua test double for client:api's :get(path_or_url, opts) interface
-- (per BUILD-NOTES.md / the shared brief: "a plain Lua test double ... that
-- returns canned paginated fixture data so pull_core's pagination logic
-- gets exercised without a real network call"). Each call consumes one
-- scripted response in order and records what it was called with, so tests
-- can assert pull_core followed the literal `next` URL rather than
-- reconstructing pagination itself.
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
        test.it("maps every field in the normalized item shape from a realistic fixture", function()
            local item = pull_core.normalize_item(raw_pr({}))
            test.eq(item.id, "42")
            test.eq(item.title, "Fix the thing")
            test.eq(item.state, "open")
            test.eq(item.author, "Ada Lovelace")
            test.eq(item.source_branch, "feature/fix-the-thing")
            test.eq(item.target_branch, "main")
            test.eq(item.created_at, "2026-01-01T00:00:00.000000+00:00")
            test.eq(item.updated_at, "2026-01-02T00:00:00.000000+00:00")
            test.is_nil(item.merged_at, "merged_at must be nil for a non-merged PR")
            test.eq(item.url, "https://bitbucket.org/acme/my-repo/pull-requests/42")
            test.not_nil(item.raw)
            test.eq(item.raw.id, 42)
        end)

        test.it("maps MERGED state and sets merged_at to updated_on only when merged", function()
            local item = pull_core.normalize_item(raw_pr({ state = "MERGED", updated_on = "2026-01-05T00:00:00.000000+00:00" }))
            test.eq(item.state, "merged")
            test.eq(item.merged_at, "2026-01-05T00:00:00.000000+00:00")
        end)

        test.it("maps DECLINED state and leaves merged_at nil", function()
            local item = pull_core.normalize_item(raw_pr({ state = "DECLINED" }))
            test.eq(item.state, "declined")
            test.is_nil(item.merged_at)
        end)

        test.it("collapses SUPERSEDED onto declined (documented information loss)", function()
            local item = pull_core.normalize_item(raw_pr({ state = "SUPERSEDED" }))
            test.eq(item.state, "declined")
            test.is_nil(item.merged_at)
        end)

        test.it("builds a lightweight key-only projection for pull_keys", function()
            local key = pull_core.normalize_key(raw_pr({ id = 7, updated_on = "2026-02-01T00:00:00.000000+00:00" }))
            test.eq(key.id, "7")
            test.eq(key.updated_at, "2026-02-01T00:00:00.000000+00:00")
            test.is_nil(key.title, "pull_keys projection must not carry full-record fields")
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
            test.eq(page.items[1].id, "1")
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
            test.eq(page2.items[1].id, "2")
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
            test.eq(items[1].id, "1")
            test.eq(items[2].id, "2")
            test.eq(items[3].id, "3")
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
            test.eq(page.items[1].id, "9")
            test.is_nil(page.items[1].title, "keys_only page must carry only the lightweight projection")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
