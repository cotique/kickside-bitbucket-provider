-- Maps HTTP/transport failures onto the DataError envelope shape confirmed
-- by the template's own kickside.data:writable sink (src/sink/write.lua in
-- the original scaffold this module was built from):
--   { code, message, retriable, scope }
-- where scope is one of item | flow | connection | provider
-- (core/contract/src/data/_index.yaml, per docs/kickside-development/
-- 02-contracts-and-ports.md). This mapping is generic HTTP-error handling,
-- not part of the unverified kickside.data:pullable envelope — see
-- source/pull.lua for that boundary.

local M = {}

-- Builds one DataError table. `retriable` defaults to false; pass true
-- explicitly for transient conditions (timeouts, 429, 5xx).
function M.new(code, message, retriable, scope)
    return {
        code = code,
        message = tostring(message),
        retriable = retriable == true,
        scope = scope or "provider",
    }
end

-- Maps a Bitbucket Cloud HTTP response (status code + optional decoded JSON
-- body) onto a DataError. Bitbucket error bodies are usually
-- `{ "error": { "message": "..." } }` (also referenced in error handling
-- elsewhere in this client), but we fall back to a generic message when the
-- body doesn't parse that way — the status code alone still ends the loop.
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

    if status_code == 401 then
        return M.new("auth_failed", message, false, "connection")
    elseif status_code == 403 then
        return M.new("forbidden", message, false, "connection")
    elseif status_code == 404 then
        return M.new("not_found", message, false, "item")
    elseif status_code == 429 then
        return M.new("rate_limited", message, true, "provider")
    elseif type(status_code) == "number" and status_code >= 500 then
        return M.new("provider_unavailable", message, true, "provider")
    elseif type(status_code) == "number" and status_code >= 400 then
        return M.new("invalid_request", message, false, "flow")
    end
    return M.new("unknown_error", message, false, "provider")
end

-- Maps a transport-level failure (DNS, connect refused, timeout — no HTTP
-- response at all) onto a retriable provider-scoped DataError.
function M.from_transport(err)
    return M.new("network_error", err, true, "provider")
end

return M
