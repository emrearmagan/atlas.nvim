local config = require("atlas.config")
local git = require("atlas.core.git")
local checkout = require("atlas.core.git.checkout")
local providers = require("atlas.providers")

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

	describe("resolve pull request repository", function()
		local original_options
		local original_isdirectory
		local original_repo_root
		local original_local_repository
		local original_resolve

		before_each(function()
			original_options = config.options
			original_isdirectory = vim.fn.isdirectory
			original_repo_root = git.repo_root
			original_local_repository = git.local_repository
			original_resolve = providers.resolve

			config.options = {
				pulls = {
					repo_config = { paths = { ["owner/repo"] = "/mapped" } },
				},
			}
			vim.fn.isdirectory = function()
				return 1
			end
			git.repo_root = function()
				return "/mapped"
			end
			git.local_repository = function()
				return { provider = "github", host = "github.com", repo_full_name = "owner/repo" }
			end
			providers.resolve = function()
				return { provider = "gitea", host = "gitea.com", repo_full_name = "owner/repo" }
			end
		end)

		after_each(function()
			config.options = original_options
			vim.fn.isdirectory = original_isdirectory
			git.repo_root = original_repo_root
			git.local_repository = original_local_repository
			providers.resolve = original_resolve
		end)

		it("ignores a mapping for the same repository on another provider", function()
			local path, err = checkout.resolve_repo_path_for_pr({
				repo_full_name = "owner/repo",
				link = { html = "https://gitea.com/owner/repo/pulls/1" },
			}, { require_git = true, require_existing = true })

			assert.is_nil(path)
			assert.equal("mapped repository does not match the pull request remote: /mapped", err)
		end)
	end)
end)
