local test = require("test")
local transport = require("transport")

local function define_tests()
    test.describe("cotique.bitbucket.client:transport credential resolution", function()
        test.it("builds a bearer-auth client for the stored access token", function()
            local client, err = transport.for_credentials({
                access_token = "fake-placeholder-value",
            })
            test.is_nil(err)
            test.not_nil(client)
        end)

        test.it("rejects credentials missing the access_token field", function()
            local client, err = transport.for_credentials({})
            test.is_nil(client)
            test.not_nil(err)
        end)

        test.it("rejects an empty access_token", function()
            local client, err = transport.for_credentials({ access_token = "" })
            test.is_nil(client)
            test.not_nil(err)
        end)
    end)

    test.describe("cotique.bitbucket.client:transport M.resolve (agent-trait connection_id -> client + workspace/repo_slug)", function()
        local function with_fake_component(private_context_by_id, fn)
            local old_component = transport._component
            transport._component = {
                get_private_context = function(connection_id)
                    local ctx = private_context_by_id[connection_id]
                    if ctx == nil then return nil, "not found" end
                    return ctx, nil
                end,
            }
            local ok, err = pcall(fn)
            transport._component = old_component
            if not ok then error(err) end
        end

        test.it("rejects a missing connection_id before reading any credentials", function()
            local resolved, err = transport.resolve(nil)
            test.is_nil(resolved)
            test.not_nil(err)

            resolved, err = transport.resolve("")
            test.is_nil(resolved)
            test.not_nil(err)
        end)

        test.it("resolves a client plus workspace/repo_slug from the connection's stored credentials", function()
            with_fake_component({
                conn1 = { access_token = "fake-placeholder-value", workspace = "acme", repo_slug = "my-repo" },
            }, function()
                local resolved, err = transport.resolve("conn1")
                test.is_nil(err)
                test.not_nil(resolved)
                test.not_nil(resolved.client)
                test.eq(resolved.workspace, "acme")
                test.eq(resolved.repo_slug, "my-repo")
            end)
        end)

        test.it("surfaces a credential read failure", function()
            with_fake_component({}, function()
                local resolved, err = transport.resolve("missing")
                test.is_nil(resolved)
                test.not_nil(err)
            end)
        end)

        test.it("rejects credentials missing workspace or repo_slug", function()
            with_fake_component({
                no_workspace = { access_token = "fake-placeholder-value", repo_slug = "my-repo" },
                no_repo_slug = { access_token = "fake-placeholder-value", workspace = "acme" },
            }, function()
                local resolved, err = transport.resolve("no_workspace")
                test.is_nil(resolved)
                test.not_nil(err)

                resolved, err = transport.resolve("no_repo_slug")
                test.is_nil(resolved)
                test.not_nil(err)
            end)
        end)

        test.it("rejects credentials missing the access_token field", function()
            with_fake_component({
                bad_creds = { workspace = "acme", repo_slug = "my-repo" },
            }, function()
                local resolved, err = transport.resolve("bad_creds")
                test.is_nil(resolved)
                test.not_nil(err)
            end)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
