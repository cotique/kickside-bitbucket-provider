local test = require("test")
local transport = require("transport")

local function define_tests()
    test.describe("cotique.bitbucket_provider.client:transport credential resolution", function()
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
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
