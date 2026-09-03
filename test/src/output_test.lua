local test = require("test")
local output = require("output")

local function define_tests()
    test.describe("cotique.bitbucket.client:output redaction", function()
        test.it("redacts credential-shaped fields by key name", function()
            local redacted = output.redact({
                username = "alice",
                app_password = "fake-placeholder-value",
                access_token = "fake-placeholder-value",
                token = "fake-placeholder-value",
                password = "fake-placeholder-value",
                nested = { authorization = "fake-placeholder-value", ok = "fine" },
            })

            test.eq(redacted.username, "alice")
            test.eq(redacted.app_password, "***redacted***")
            test.eq(redacted.access_token, "***redacted***")
            test.eq(redacted.token, "***redacted***")
            test.eq(redacted.password, "***redacted***")
            test.eq(redacted.nested.authorization, "***redacted***")
            test.eq(redacted.nested.ok, "fine")
        end)

        test.it("is case-insensitive on sensitive key names", function()
            local redacted = output.redact({ ["Access_Token"] = "fake-placeholder-value" })
            test.eq(redacted["Access_Token"], "***redacted***")
        end)

        test.it("passes non-table values through untouched", function()
            test.eq(output.redact("plain string"), "plain string")
            test.eq(output.redact(42), 42)
            test.eq(output.redact(nil), nil)
        end)

        test.it("leaves ordinary fields alone", function()
            local redacted = output.redact({ workspace = "acme", repo_slug = "my-repo" })
            test.eq(redacted.workspace, "acme")
            test.eq(redacted.repo_slug, "my-repo")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
