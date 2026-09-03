local test = require("test")
local discover_resources = require("discover_resources")

local function define_tests()
    test.describe("cotique.bitbucket.connection discover_resources normalization", function()
        test.it("normalizes a Bitbucket repository to the discover_resources shape", function()
            -- Fixture shaped like a real GET /repositories response item
            -- (field names per BUILD-NOTES.md's empirically-verified payload).
            local repo = {
                uuid = "{5c4d3c1a-aaaa-bbbb-cccc-1234567890ab}",
                full_name = "acme/my-repo",
                name = "my-repo",
                is_private = true,
            }

            local resource = discover_resources.normalize_repo(repo)

            test.eq(resource.id, "{5c4d3c1a-aaaa-bbbb-cccc-1234567890ab}")
            test.eq(resource.label, "acme/my-repo")
            test.eq(resource.icon, "tabler:brand-bitbucket")
            test.is_nil(resource.parent_id)
            test.is_true(resource.selectable)
            test.eq(resource.drillable, false)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
