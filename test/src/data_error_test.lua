local test = require("test")
local data_error = require("data_error")

local function define_tests()
    test.describe("cotique.bitbucket_provider.client:data_error bare record builders (client/api.lua's own convention)", function()
        test.it("builds a bare DataError record", function()
            local err = data_error.new("some_code", "some message", true, "item")
            test.eq(err.code, "some_code")
            test.eq(err.message, "some message")
            test.eq(err.retriable, true)
            test.eq(err.scope, "item")
        end)

        test.it("defaults retriable to false", function()
            local err = data_error.new("some_code", "some message", nil, "provider")
            test.eq(err.retriable, false)
            test.eq(err.scope, "provider")
        end)

        test.it("maps 401 to a non-retriable connection-scoped auth_expired", function()
            local err = data_error.from_http(401, nil, "Unauthorized")
            test.eq(err.code, "auth_expired")
            test.eq(err.retriable, false)
            test.eq(err.scope, "connection")
        end)

        test.it("maps 403 to a non-retriable flow-scoped permission_denied", function()
            local err = data_error.from_http(403, nil, "Forbidden")
            test.eq(err.code, "permission_denied")
            test.eq(err.retriable, false)
            test.eq(err.scope, "flow")
        end)

        test.it("maps 404 to a non-retriable flow-scoped not_found", function()
            local err = data_error.from_http(404, nil, "Not Found")
            test.eq(err.code, "not_found")
            test.eq(err.scope, "flow")
        end)

        test.it("maps 429 to a retriable provider-scoped rate_limited", function()
            local err = data_error.from_http(429, nil, "Rate limit exceeded")
            test.eq(err.code, "rate_limited")
            test.eq(err.retriable, true)
            test.eq(err.scope, "provider")
        end)

        test.it("maps 5xx to a retriable provider_unavailable", function()
            local err = data_error.from_http(503, nil, "Service Unavailable")
            test.eq(err.code, "provider_unavailable")
            test.eq(err.retriable, true)
            test.eq(err.scope, "provider")
        end)

        test.it("folds other 4xx (e.g. 400) into the real taxonomy's generic provider_error fallback", function()
            -- github/src/client/data_error.lua's own M.from_result has no
            -- dedicated "bad request" bucket — only 401/403/404/429/5xx are
            -- special-cased, everything else (including 400/422) falls to
            -- the generic retriable provider_error bucket. Confirmed real,
            -- not a guess — see BUILD-NOTES.md.
            local err = data_error.from_http(400, nil, "Bad Request")
            test.eq(err.code, "provider_error")
            test.eq(err.retriable, true)
            test.eq(err.scope, "provider")
        end)

        test.it("prefers the decoded Bitbucket error.message body when present", function()
            local err = data_error.from_http(400, { error = { message = "workspace not found" } }, "{}")
            test.eq(err.message, "workspace not found")
        end)

        test.it("maps a transport failure to a retriable provider-scoped network_error", function()
            local err = data_error.from_transport("connection refused")
            test.eq(err.code, "network_error")
            test.eq(err.retriable, true)
            test.eq(err.scope, "provider")
        end)
    end)

    test.describe("cotique.bitbucket_provider.client:data_error real taxonomy envelope builders (pull_core.lua's convention)", function()
        test.it("M.failure builds a full pullable failure envelope", function()
            local out = data_error.failure("some_code", "some message", true, "provider")
            test.eq(out.success, false)
            test.eq(out.error.code, "some_code")
            test.eq(out.error.message, "some message")
            test.eq(out.error.retriable, true)
            test.eq(out.error.scope, "provider")
        end)

        test.it("M.failure sets auth_expired=true and forwards retry_after_ms", function()
            local out = data_error.failure("auth_expired", "expired", false, "connection")
            test.eq(out.error.auth_expired, true)

            local rl = data_error.failure("rate_limited", "slow down", true, "provider", 2000)
            test.eq(rl.retry_after_ms, 2000)
        end)

        test.it("M.connection builds an auth_expired connection-scoped envelope", function()
            local out = data_error.connection("revoked")
            test.eq(out.success, false)
            test.eq(out.error.code, "auth_expired")
            test.eq(out.error.scope, "connection")
            test.eq(out.error.message, "revoked")
        end)

        test.it("M.invalid_config builds an invalid_config flow-scoped envelope", function()
            local out = data_error.invalid_config("config.workspace is required")
            test.eq(out.success, false)
            test.eq(out.error.code, "invalid_config")
            test.eq(out.error.scope, "flow")
        end)

        test.it("M.from_result re-wraps a bare DataError as a full envelope with an action-prefixed message", function()
            local bare = data_error.from_http(404, nil, "Not Found")
            local out = data_error.from_result(bare, "list Bitbucket pull requests")
            test.eq(out.success, false)
            test.eq(out.error.code, "not_found")
            test.eq(out.error.message, "list Bitbucket pull requests: Not Found")
            test.eq(out.error.scope, "flow")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
