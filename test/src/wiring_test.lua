-- Registry-shape test for the module's contract bindings and automation
-- port. This module ships no web component, no custom HTTP endpoint, and no
-- security policy of its own — matches the real reference provider modules
-- (kickside/discord, kickside/slack, etc.; see BUILD-NOTES.md "structural
-- audit"). The standalone harness cannot open contracts under an
-- actor/scope (see docs/kickside-development/13-testing.md "Harness
-- Limits"), so connection/source behavior is verified as registry wiring
-- here; the underlying logic (normalization, pagination, redaction) is
-- proven by the colocated *_test.lua suites next to their source.
local test = require("test")
local registry = require("registry")

local NS = "cotique.bitbucket_provider"

local CONNECTION_ID = "cotique.bitbucket_provider.connection:bitbucket_connection"
local SOURCE_BINDING_ID = "cotique.bitbucket_provider.source:repo_pulls_source"
local SOURCE_PORT_ID = "cotique.bitbucket_provider.source:repo_pulls"
local PULL_ITEMS_ID = "cotique.bitbucket_provider.source:pull_items"
local PULL_KEYS_ID = "cotique.bitbucket_provider.source:pull_keys"

local function get(id)
    local entry, err = registry.get(id)
    test.is_nil(err)
    test.not_nil(entry, id .. " is missing")
    return entry
end

local function meta_of(entry)
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

-- Entry references are written relative or namespace-qualified; compare fully
-- qualified.
local function qualify(ref, ns)
    if type(ref) ~= "string" then return ref end
    if ref:find(":", 1, true) then return ref end
    return ns .. ":" .. ref
end

local function define_tests()
    test.describe("cotique.bitbucket_provider surface wiring", function()
        test.it("declares the Bitbucket connection provider binding with a credential_schema", function()
            local conn = get(CONNECTION_ID)
            test.eq(conn.kind, "contract.binding")
            local m = meta_of(conn)
            test.eq(m.provider, "bitbucket")
            test.not_nil(m.credential_schema, "connection binding must declare a credential_schema")
            test.not_nil(m.credential_schema.fields, "credential_schema must declare fields")

            local has_access_token = false
            for _, f in ipairs(m.credential_schema.fields) do
                if f.key == "access_token" then has_access_token = true end
            end
            test.is_true(has_access_token, "credential_schema must declare the access_token field")
        end)

        test.it("wires the get_status/test_connection/discover_resources/delete function entries", function()
            get("cotique.bitbucket_provider.connection:get_status")
            get("cotique.bitbucket_provider.connection:delete")
            get("cotique.bitbucket_provider.connection:test_connection")
            get("cotique.bitbucket_provider.connection:discover_resources")
        end)

        test.it("declares the pull request source binding implementing kickside.data:pullable", function()
            local source = get(SOURCE_BINDING_ID)
            test.eq(source.kind, "contract.binding")
            get(PULL_ITEMS_ID)
            get(PULL_KEYS_ID)
        end)

        test.it("publishes the pull request source as an automation port bound to the source binding", function()
            local port = get(SOURCE_PORT_ID)
            local m = meta_of(port)
            test.eq(m.type, "kickside.automation.port")
            local d = data_of(port)
            test.eq(qualify(d.binding, NS .. ".source"), SOURCE_BINDING_ID)
            test.not_nil(d.config_schema, "port must declare a config_schema")
            test.not_nil(d.config_schema.workspace, "port config_schema must let the user select a workspace")
            test.not_nil(d.config_schema.repo_slug, "port config_schema must let the user select a repository")
            test.not_nil(d.output_schema, "port must declare an output_schema")
            test.not_nil(d.operations, "port must declare its operations")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
