local checkout = require("atlas.core.git.checkout")

describe("repo_paths", function()
	describe("validate", function()
		it("accepts valid mappings", function()
			local ok = checkout.validate_repo_paths({
				["ws/*"] = "~/code/*",
				["ws/repo"] = "~/code/special",
			})

			assert.is_true(ok)
		end)

		it("fails when wildcard parity is wrong", function()
			local ok = checkout.validate_repo_paths({
				["ws/*"] = "~/code/no-star",
			})

			assert.is_false(ok)
		end)
	end)

	describe("resolve", function()
		it("resolves exact mapping over wildcard", function()
			local path = checkout.resolve_repo_path(
				{
					["ws/*"] = "~/code/*",
					["ws/repo"] = "~/code/special",
				},
				"ws/repo",
				{
					require_git = false,
					require_existing = false,
				}
			)

			assert.is_string(path)
			assert.is_truthy(path:find("special"))
		end)

		it("resolves wildcard mapping", function()
			local path = checkout.resolve_repo_path(
				{
					["ws/*"] = "~/code/*",
				},
				"ws/abc",
				{
					require_git = false,
					require_existing = false,
				}
			)

			assert.is_string(path)
			assert.is_truthy(path:find("abc"))
		end)
	end)
end)
