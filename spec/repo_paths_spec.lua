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

		it("prefers more specific wildcard", function()
			-- "ws/proj-*" is more specific (longer literal) than "ws/*".
			local path = checkout.resolve_repo_path({
				["ws/*"] = "~/code/*",
				["ws/proj-*"] = "~/work/proj-*",
			}, "ws/proj-foo", { require_git = false, require_existing = false })
			assert.is_truthy(path:find("/work/proj%-foo$"))
		end)

		it("substitutes multiple captures in order", function()
			local path = checkout.resolve_repo_path(
				{ ["ws/proj-*-v*"] = "~/code/*/v*" },
				"ws/proj-foo-v2",
				{ require_git = false, require_existing = false }
			)
			assert.is_truthy(path:find("/code/foo/v2$"))
		end)

		it("does not match across workspaces", function()
			local path, err = checkout.resolve_repo_path(
				{ ["ws/*"] = "~/code/*" },
				"other/repo",
				{ require_git = false, require_existing = false }
			)
			assert.is_nil(path)
			assert.is_truthy(err)
		end)

		it("returns error when nothing matches", function()
			local path, err = checkout.resolve_repo_path(
				{ ["ws/specific"] = "~/code/specific" },
				"ws/other",
				{ require_git = false, require_existing = false }
			)
			assert.is_nil(path)
			assert.is_truthy(err)
		end)
	end)

	describe("validate", function()
		it("rejects keys without workspace/repo shape", function()
			local ok = checkout.validate_repo_paths({ ["bad"] = "~/x" })
			assert.is_false(ok)
		end)
	end)
end)
