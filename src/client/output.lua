-- Safe output encoding: redacts credential-shaped fields from any table
-- before it reaches a log line, an error message, or anything else that
-- could be persisted or displayed. Per AGENTS.md: "Never log tokens,
-- credentials, private component context, authorization headers, or full
-- user payloads."

local M = {}

local REDACTED = "***redacted***"

-- Case-insensitive key names that must never appear in cleartext in output.
local SENSITIVE_KEYS = {
    ["token"] = true,
    ["access_token"] = true,
    ["app_password"] = true,
    ["password"] = true,
    ["authorization"] = true,
    ["auth"] = true,
    ["secret"] = true,
    ["private_context"] = true,
}

local function is_sensitive(key)
    if type(key) ~= "string" then return false end
    return SENSITIVE_KEYS[key:lower()] == true
end

-- Deep-copies a value, replacing any sensitive-keyed field with a redaction
-- marker. Bounded recursion depth guards against cycles — past the bound it
-- gives up descending and returns the value as-is rather than a differently
-- typed placeholder. Non-table values pass through untouched.
function M.redact(value, _depth)
    if type(value) ~= "table" then return value end

    local depth = (_depth or 0) + 1
    if depth > 20 then return value end

    local out = {}
    for k, v in pairs(value) do
        if is_sensitive(k) then
            out[k] = REDACTED
        else
            out[k] = M.redact(v, depth)
        end
    end
    return out
end

return M
