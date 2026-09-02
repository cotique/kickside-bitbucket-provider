local test = require("test")
local transport = require("transport")

local function define_tests()
    test.describe("cotique.bitbucket_provider.client:transport credential resolution", function()
        test.it("builds a basic-auth client for app_password mode", function()
            local client, err = transport.for_credentials({
                auth_mode = "app_password",
                username = "alice",
                app_password = "fake-placeholder-value",
            })
            test.is_nil(err)
            test.not_nil(client)
        end)

        test.it("builds a bearer-auth client for access_token mode", function()
            local client, err = transport.for_credentials({
                auth_mode = "access_token",
                access_token = "fake-placeholder-value",
            })
            test.is_nil(err)
            test.not_nil(client)
        end)

        test.it("defaults to app_password mode when auth_mode is not set", function()
            local client, err = transport.for_credentials({
                username = "alice",
                app_password = "fake-placeholder-value",
            })
            test.is_nil(err)
            test.not_nil(client)
        end)

        test.it("rejects app_password mode missing the app_password field", function()
            local client, err = transport.for_credentials({ auth_mode = "app_password", username = "alice" })
            test.is_nil(client)
            test.not_nil(err)
        end)

        test.it("rejects access_token mode missing the access_token field", function()
            local client, err = transport.for_credentials({ auth_mode = "access_token" })
            test.is_nil(client)
            test.not_nil(err)
        end)

        test.it("rejects an unknown auth_mode", function()
            local client, err = transport.for_credentials({ auth_mode = "carrier_pigeon" })
            test.is_nil(client)
            test.not_nil(err)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
