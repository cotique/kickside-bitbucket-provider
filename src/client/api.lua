-- Low-level Bitbucket Cloud REST client. Builds requests, sets the auth
-- header for whichever credential mode was configured, parses JSON, and
-- returns a DataError (client:data_error shape) on any non-2xx or transport
-- failure. This is the fully-verified layer: base URL, auth header shapes,
-- and pagination handling all match the empirically-confirmed behavior in
-- BUILD-NOTES.md ("Empirically-verified REST API pagination shapes").
--
-- No dependency on the kickside.data:pullable envelope — this client is
-- exercised directly by pull_core.lua's own tests via a fake `client`
-- object satisfying the same :get(path, opts) interface, so its pagination
-- logic is provable without a real network call.
--
-- :post/:put (added for the write-access agent-tool traits, traits/*) are
-- NOT empirically verified against a live call the way :get's shapes are —
-- per the write-access brief, no write call was made against a real
-- repository this pass. They are built against the documented request/
-- response shapes confirmed live in the browser against
-- https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/
-- (create/update/decline a pull request, create a pull request comment —
-- see BUILD-NOTES.md's write-access entry for exactly what was read there),
-- and exercised only indirectly, through traits/write_tool.lua's tests
-- against a fake client object — the same testing posture :get itself has
-- always had here (there is no colocated api_test.lua for either verb;
-- http_client is an ambient host module with no dependency-injection seam
-- in this file).

local http_client = require("http_client")
local json = require("json")
local base64 = require("base64")
local data_error = require("data_error")
local types = require("types")

local M = {}

-- Resolves `path_or_url` to a full URL. Bitbucket's own pagination `next`
-- field is already a complete absolute URL (per the empirically-verified
-- shape) and must be followed literally, not reconstructed — see
-- BUILD-NOTES.md. Anything not already absolute is joined onto base_url.
local function resolve_url(base_url, path_or_url)
    if type(path_or_url) == "string" and path_or_url:match("^https?://") then
        return path_or_url
    end
    local path = path_or_url or ""
    if path ~= "" and path:sub(1, 1) ~= "/" then path = "/" .. path end
    return base_url .. path
end

-- opts: {
--   base_url    = string, defaults to types.BASE_URL
--   auth_mode   = types.AUTH_MODE.APP_PASSWORD | types.AUTH_MODE.ACCESS_TOKEN
--   username    = string (required for APP_PASSWORD)
--   app_password = string (required for APP_PASSWORD)
--   access_token = string (required for ACCESS_TOKEN)
--   timeout     = string, defaults to "30s"
-- }
--
-- Returns a plain table with one method, :get(path_or_url, opts). auth
-- header/base_url/timeout are closed over as locals (not table fields) so
-- their concrete string type is preserved through to the http_client call
-- below, rather than widening to unknown through a self-field OOP pattern.
function M.new(opts)
    opts = type(opts) == "table" and opts or {}

    local auth_header
    if opts.auth_mode == types.AUTH_MODE.APP_PASSWORD then
        if type(opts.username) ~= "string" or opts.username == ""
            or type(opts.app_password) ~= "string" or opts.app_password == "" then
            return nil, "app_password auth requires both username and app_password"
        end
        local token = base64.encode(opts.username .. ":" .. opts.app_password)
        auth_header = "Basic " .. token
    elseif opts.auth_mode == types.AUTH_MODE.ACCESS_TOKEN then
        if type(opts.access_token) ~= "string" or opts.access_token == "" then
            return nil, "access_token auth requires access_token"
        end
        auth_header = "Bearer " .. opts.access_token
    else
        return nil, "unknown auth_mode: " .. tostring(opts.auth_mode)
    end

    local base_url = types.BASE_URL
    if type(opts.base_url) == "string" then base_url = opts.base_url end

    local timeout = "30s"
    if type(opts.timeout) == "string" then timeout = opts.timeout end

    local client = {}

    -- GET path_or_url. `req_opts.query` is a table of query params, only
    -- used when path_or_url is relative (an already-absolute `next` URL
    -- carries its own query string and must not be re-queried). Returns
    -- (decoded_json, nil) on 2xx, or (nil, data_error) on any failure.
    function client:get(path_or_url, req_opts)
        req_opts = type(req_opts) == "table" and req_opts or {}
        local url = resolve_url(base_url, path_or_url)
        local is_absolute = type(path_or_url) == "string" and path_or_url:match("^https?://") ~= nil

        local headers = { ["Authorization"] = auth_header, ["Accept"] = "application/json" }

        local resp, err
        if type(req_opts.query) == "table" and not is_absolute then
            resp, err = http_client.get(url, { headers = headers, timeout = timeout, query = req_opts.query })
        else
            resp, err = http_client.get(url, { headers = headers, timeout = timeout })
        end
        if err then
            return nil, data_error.from_transport(err)
        end
        if not resp or type(resp.status_code) ~= "number" then
            return nil, data_error.new("network_error", "no response from Bitbucket", true, "provider")
        end

        if resp.status_code < 200 or resp.status_code >= 300 then
            local decoded = nil
            if type(resp.body) == "string" and resp.body ~= "" then
                decoded = json.decode(resp.body)
            end
            return nil, data_error.from_http(resp.status_code, decoded, resp.body)
        end

        if type(resp.body) ~= "string" or resp.body == "" then
            return {}, nil
        end

        local decoded, derr = json.decode(resp.body)
        if derr then
            return nil, data_error.new("invalid_response", "could not decode Bitbucket response: " .. tostring(derr), false, "provider")
        end
        return decoded, nil
    end

    -- POST/PUT path_or_url with an optional JSON-encoded `body`. `body ==
    -- nil` sends no request body at all (Bitbucket's PR decline endpoint
    -- takes none). Returns (decoded_json, nil) on 2xx, or (nil, data_error)
    -- on any failure — the same two-value bare-DataError-record convention
    -- :get above uses. Deliberately self-contained rather than sharing :get's
    -- implementation, so this addition cannot change :get's already-tested
    -- behavior; some tail logic is duplicated on purpose.
    --
    -- auth_header/req_base_url/req_timeout are taken as explicit parameters
    -- rather than captured as upvalues (unlike :get above, which does
    -- capture auth_header/base_url/timeout as upvalues): confirmed via
    -- `wippy lint` that having a *second* closure in this same M.new scope
    -- also capture those same upvalues made Luau's type inference for
    -- :get's own already-working http_client.get(...) calls widen to an
    -- unresolved/unknown type and start failing lint, even though :get's
    -- own code was untouched. Passing the values as plain call arguments
    -- instead avoids the shared-upvalue-capture interaction entirely; the
    -- values themselves and the resulting request are identical.
    local function write_request(req_auth_header, req_base_url, req_timeout, method, path_or_url, body)
        local url = resolve_url(req_base_url, path_or_url)
        local headers = { ["Authorization"] = req_auth_header, ["Accept"] = "application/json" }

        -- Two inline table-literal call sites (mirroring :get's own
        -- two-branch shape above), not one named `req_opts` local built up
        -- across statements then passed by reference: confirmed via `wippy
        -- lint` that a literal table constructed directly at the call site
        -- type-checks against http_client's options type, while an
        -- equivalent-shaped named local built incrementally does not (the
        -- checker's record-vs-index-signature width subtyping only kicks
        -- in for a fresh literal argument). Same request either way.
        local resp, err
        if body ~= nil then
            local encoded, eerr = json.encode(body)
            if eerr then
                return nil, data_error.new("invalid_config", "could not encode Bitbucket request body: " .. tostring(eerr), false, "flow")
            end
            headers["Content-Type"] = "application/json"
            resp, err = http_client.request(method, url, { headers = headers, timeout = req_timeout, body = encoded })
        else
            resp, err = http_client.request(method, url, { headers = headers, timeout = req_timeout })
        end
        if err then
            return nil, data_error.from_transport(err)
        end
        if not resp or type(resp.status_code) ~= "number" then
            return nil, data_error.new("network_error", "no response from Bitbucket", true, "provider")
        end

        if resp.status_code < 200 or resp.status_code >= 300 then
            local decoded = nil
            if type(resp.body) == "string" and resp.body ~= "" then
                decoded = json.decode(resp.body)
            end
            return nil, data_error.from_http(resp.status_code, decoded, resp.body)
        end

        if type(resp.body) ~= "string" or resp.body == "" then
            return {}, nil
        end

        local decoded, derr = json.decode(resp.body)
        if derr then
            return nil, data_error.new("invalid_response", "could not decode Bitbucket response: " .. tostring(derr), false, "provider")
        end
        return decoded, nil
    end

    -- Plain field assignment (`client.post = function(self, ...)`), not
    -- `function client:post(...)` colon sugar: confirmed via `wippy lint`
    -- that adding a second/third colon-sugar method on `client` in this
    -- scope, referencing the same auth_header/base_url/timeout upvalues
    -- :get already captures, made Luau's type inference for :get's own
    -- unmodified http_client.get(...) calls widen to an unresolved type
    -- and start failing lint — this form avoids that interaction. Still
    -- callable as `client:post(path_or_url, body)` (colon call syntax
    -- passes `client` itself as `self`, ignored here).
    client.post = function(self, path_or_url, body)
        return write_request(auth_header, base_url, timeout, "POST", path_or_url, body)
    end

    client.put = function(self, path_or_url, body)
        return write_request(auth_header, base_url, timeout, "PUT", path_or_url, body)
    end

    return client
end

return M
