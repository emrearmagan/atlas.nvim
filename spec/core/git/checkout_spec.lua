local checkout = require("atlas.core.git.checkout")

local function resolve(paths, repo)
	return checkout.resolve_repo_path(paths, repo, {
		require_git = false,
		require_existing = false,
	})
end

describe("core.git.checkout", function()
	it("uses the pull request snapshot commits for diffs", function()
		local base, head = checkout.pr_diff_revisions({
			destination = { commit_hash = "base123" },
			source = { commit_hash = "head456" },
		})

		assert.equal("base123", base)
		assert.equal("head456", head)
	end)

	describe("validate", function()
		it("fails when wildcard parity is wrong", function()
			local ok = checkout.validate_repo_paths({
				["ws/*"] = "~/code/no-star",
			})

			assert.is_false(ok)
		end)

		it("rejects keys without workspace/repo shape", function()
			local ok = checkout.validate_repo_paths({ ["bad"] = "~/x" })
			assert.is_false(ok)
		end)
	end)

	describe("resolve", function()
		it("resolves exact mapping over wildcard", function()
			local path = resolve({
				["ws/*"] = "~/code/*",
				["ws/repo"] = "~/code/special",
			}, "ws/repo")

			assert.is_string(path)
			assert.is_truthy(path:find("special"))
		end)

		it("resolves wildcard mapping", function()
			local path = resolve({ ["ws/*"] = "~/code/*" }, "ws/abc")

			assert.is_string(path)
			assert.is_truthy(path:find("abc"))
		end)

		it("prefers more specific wildcard", function()
			local path = resolve({
				["ws/*"] = "~/code/*",
				["ws/proj-*"] = "~/work/proj-*",
			}, "ws/proj-foo")
			assert.is_truthy(path:find("/work/proj%-foo$"))
		end)

		it("substitutes multiple captures in order", function()
			local path = resolve({ ["ws/proj-*-v*"] = "~/code/*/v*" }, "ws/proj-foo-v2")
			assert.is_truthy(path:find("/code/foo/v2$"))
		end)

		it("does not match across workspaces", function()
			local path, err = resolve({ ["ws/*"] = "~/code/*" }, "other/repo")
			assert.is_nil(path)
			assert.is_truthy(err)
		end)
	end)
end)
