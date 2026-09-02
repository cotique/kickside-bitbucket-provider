-- Maps HTTP/transport failures and pullable-envelope-level validation
-- failures onto the kickside.data DataError taxonomy.
--
-- Rewritten to match the REAL, ground-truth
-- providers-master\providers-master\github\src\client\data_error.lua (local
-- unpacked copy of git.wippy.ai/kickside/providers, see BUILD-NOTES.md
-- "RESOLVED: kickside.data:pullable envelope"): same function names
-- (M.failure / M.connection / M.invalid_config / M.from_result), same full
-- pullable-envelope return shape
-- ({ success = false, error = { code, message, retriable, scope
-- [, auth_expired] } [, retry_after_ms] }), and the same code vocabulary
-- (auth_expired, invalid_config, permission_denied, not_found, rate_limited,
-- provider_unavailable, provider_error) — replacing the vocabulary this
-- module previously inferred by analogy (auth_failed, forbidden,
-- unknown_error, invalid_request, and a bare {code,message,retriable,scope}
-- record with no envelope at all).
--
-- source/pull_core.lua's M.pull/M.pull_keys call M.connection/
-- M.invalid_config/M.from_result directly and return the result AS the
-- pullable envelope response, exactly like the real github/jira pull_core.
--
-- client/api.lua (out of scope for this fix — independently confirmed
-- correct, see BUILD-NOTES.md) follows a `(decoded, err)` two-value Lua
-- convention for :get(), where `err` is a *bare* {code,message,retriable,
-- scope} record, not a {success=false,error=...} envelope —
-- connection/test_connection.lua and connection/discover_resources.lua
-- (also out of scope) read `err.message` directly off that bare record and
-- must keep working unchanged. M.new/M.from_http/M.from_transport below are
-- this module's own pre-existing functions, kept under their original
-- names (so api.lua needs no call-site renaming) but rewritten onto the
-- real taxonomy's code vocabulary: M.new(code,message,retriable,scope) is
-- exactly M.failure(code,message,retriable,scope).error.

local M = {}

-- Builds one full pullable-envelope failure response, matching the real
-- github/src/client/data_error.lua M.failure exactly.
function M.failure(code, message, retriable, scope, retry_after_ms)
    local err = { code = code, message = tostring(message), retriable = retriable == true, scope = scope }
    if code == "auth_expired" then err.auth_expired = true end
    local out = { success = false, error = err }
    if retry_after_ms ~= nil then out.retry_after_ms = retry_after_ms end
    return out
end

-- Connection-scoped auth failure — credential revoked/expired/unresolvable.
function M.connection(message)
    return M.failure("auth_expired", message, false, "connection")
end

-- Request-shape validation failure (missing/invalid config), raised before
-- any network call is attempted.
function M.invalid_config(message)
    return M.failure("invalid_config", message, false, "flow")
end

-- Bare {code,message,retriable,scope} record — no success/error envelope
-- wrapper. This module's own addition (not part of the real github
-- taxonomy file), needed because client/api.lua's :get() returns exactly
-- this shape as its second value; see the file header for why.
function M.new(code, message, retriable, scope)
    return M.failure(code, message, retriable, scope).error
end

-- Maps a Bitbucket Cloud HTTP response (status code + optional decoded JSON
-- body) onto a bare DataError record, using the real taxonomy's code
-- vocabulary. Bitbucket error bodies are usually
-- `{ "error": { "message": "..." } }`, but falls back to the raw body, then
-- a generic message, when that doesn't parse.
function M.from_http(status_code, decoded_body, raw_body)
    local message
    if type(decoded_body) == "table" and type(decoded_body.error) == "table"
        and type(decoded_body.error.message) == "string" then
        message = decoded_body.error.message
    elseif type(raw_body) == "string" and raw_body ~= "" then
        message = raw_body
    else
        message = "Bitbucket API returned HTTP " .. tostring(status_code)
    end

    if status_code == 401 then return M.new("auth_expired", message, false, "connection") end
    if status_code == 403 then return M.new("permission_denied", message, false, "flow") end
    if status_code == 404 then return M.new("not_found", message, false, "flow") end
    if status_code == 429 then return M.new("rate_limited", message, true, "provider") end
    if type(status_code) == "number" and status_code >= 500 then return M.new("provider_unavailable", message, true, "provider") end
    -- Every other status (including other 4xx like 400/422) folds into the
    -- real taxonomy's generic fallback bucket — confirmed in
    -- github/src/client/data_error.lua's own M.from_result, which has no
    -- dedicated "bad request" code either.
    return M.new("provider_error", message, true, "provider")
end

-- Maps a transport-level failure (DNS, connect refused, timeout — no HTTP
-- response at all) onto a retriable provider-scoped DataError. No
-- real-taxonomy equivalent (github's own transport pre-decodes and never
-- surfaces this failure mode to data_error.lua at all) — kept as this
-- connector's own addition for the failure mode api.lua does see.
function M.from_transport(err)
    return M.new("network_error", err, true, "provider")
end

-- Real taxonomy's M.from_result(result, action) — maps a failure result
-- onto a full pullable envelope, prefixing the message with `action` for
-- context, matching github's own usage
-- (`data_error.from_result(result, "list GitHub issues")`). Adapted for
-- this connector's actual client shape: api.lua's :get() already turns an
-- HTTP response into a bare DataError via M.from_http above (unlike
-- github's transport, which hands back an undecoded
-- {success,status_code,error,data} result for from_result to classify
-- itself) — so `result` here IS that already-classified bare DataError, and
-- this just re-wraps it as the envelope source/pull_core.lua's
-- M.pull/M.pull_keys return directly.
function M.from_result(result, action)
    local r = type(result) == "table" and result or {}
    local code = type(r.code) == "string" and r.code or "provider_error"
    local message = tostring(action) .. ": " .. tostring(r.message or "request failed")
    return M.failure(code, message, r.retriable == true, r.scope or "provider")
end

return M
