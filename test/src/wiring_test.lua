-- Registry-shape test for the module's contract bindings, automation port,
-- HTTP/UI surfaces, and security policy. The standalone harness cannot open
-- contracts under an actor/scope (see docs/kickside-development/
-- 13-testing.md "Harness Limits"), so connection/source behavior is verified
-- as registry wiring here; the underlying logic (normalization, pagination,
-- redaction) is proven by the colocated *_test.lua suites next to their
-- source.
local test = require("test")
local registry = require("registry")

local NS = "cotique.bitbucket_provider"
local HANDLER_ID = "cotique.bitbucket_provider.api:get_status"
local ENDPOINT_ID = "cotique.bitbucket_provider.api:get_status.endpoint"
local VIEW_ID = "cotique.bitbucket_provider:bitbucket_provider_view"
local NAV_ID = "cotique.bitbucket_provider:nav_item"
local STATIC_ID = "cotique.bitbucket_provider:ui_static"
local FS_ID = "cotique.bitbucket_provider:ui_fs"
local POLICY_ID = "cotique.bitbucket_provider.security:bitbucket_provider_endpoint_access"

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
        test.it("pairs the status endpoint with its handler on the router token", function()
            get(HANDLER_ID)
            local ep = data_of(get(ENDPOINT_ID))
            test.eq(qualify(ep.func, "cotique.bitbucket_provider.api"), HANDLER_ID)
            test.eq(ep.method, "GET")
            test.eq(ep.path, "/bitbucket-provider/status")
            test.eq(meta_of(get(ENDPOINT_ID)).router, "app:api")
        end)

        test.it("declares a view served by the module's own static mount", function()
            local view = meta_of(get(VIEW_ID))
            test.eq(view.type, "view.component")
            test.eq(view.tag_name, "cotique-bitbucket-provider")
            test.eq(view.entry_point, "index.js")
            test.eq(view.announced, true)
            test.eq(view.auto_register, true)

            local static = get(STATIC_ID)
            test.eq(data_of(static).path, "/" .. view.base_path)
            test.eq(qualify(data_of(static).fs, NS), FS_ID)
            get(FS_ID)
        end)

        test.it("mounts the view in the app nav by tag", function()
            local nav = meta_of(get(NAV_ID))
            test.eq(nav.type, "ui.nav_item")
            test.eq(nav.path, "/bitbucket-provider")
            test.eq(nav.render, "component")
            test.eq(nav.component_tag, meta_of(get(VIEW_ID)).tag_name)
        end)

        test.it("gates the api namespace behind the injectable access policy", function()
            local policy = data_of(get(POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = { resources } end
            local covered = false
            for _, r in ipairs(resources) do
                if r == "cotique.bitbucket_provider.api:*" then covered = true end
            end
            test.is_true(covered, "policy must cover cotique.bitbucket_provider.api:*")
        end)

        test.it("declares the Bitbucket connection provider binding with a credential_schema", function()
            local conn = get(CONNECTION_ID)
            test.eq(conn.kind, "contract.binding")
            local m = meta_of(conn)
            test.eq(m.provider, "bitbucket")
            test.not_nil(m.credential_schema, "connection binding must declare a credential_schema")
            test.not_nil(m.credential_schema.fields, "credential_schema must declare fields")

            local has_auth_mode = false
            for _, f in ipairs(m.credential_schema.fields) do
                if f.key == "auth_mode" then has_auth_mode = true end
            end
            test.is_true(has_auth_mode, "credential_schema must declare the auth_mode selector")
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
