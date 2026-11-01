local remotes = require("atlas.pulls.create.remotes")

---@param name string
---@param slug string|nil
---@param provider string|nil
---@param host string|nil
---@return AtlasCreateRemote
local function remote(name, slug, provider, host)
	local target
	if slug then
		target = {
			provider = provider or "github",
			host = host or "github.com",
			repo_full_name = slug,
		}
	end
	return { name = name, url = "https://example.com/" .. name, target = target }
end

describe("pulls.create.remotes", function()
	describe("base_remote", function()
		it("prefers upstream like gh", function()
			local value = remotes.base_remote({
				remote("origin", "me/repo"),
				remote("upstream", "parent/repo"),
			})

			assert.equal("upstream", assert(value).name)
		end)

		it("falls back to the first supported remote", function()
			local value = remotes.base_remote({
				remote("mirror"),
				remote("parent", "parent/repo"),
				remote("fork", "me/repo"),
			})

			assert.equal("parent", assert(value).name)
		end)

		it("uses the tracked remote before origin", function()
			local value = remotes.base_remote({
				remote("origin", "me/repo"),
				remote("parent", "parent/repo"),
			}, "parent")

			assert.equal("parent", assert(value).name)
		end)

		it("uses the gh or glab default before the tracked remote", function()
			local value = remotes.base_remote({
				remote("origin", "me/repo"),
				remote("upstream", "parent/repo"),
			}, "upstream", { origin = "base" })

			assert.equal("origin", assert(value).name)
		end)

		it("ignores an unsupported tracked remote", function()
			local value = remotes.base_remote({
				remote("origin", "me/repo"),
				remote("mirror"),
			}, "mirror")

			assert.equal("origin", assert(value).name)
		end)

		it("requires at least one supported remote", function()
			local value, err = remotes.base_remote({ remote("mirror") })
			assert.is_nil(value)
			assert.matches("No supported Git remote", assert(err), 1, true)
		end)
	end)

	describe("same_repository", function()
		it("compares the head target with the base repository", function()
			assert.is_true(remotes.same_repository(nil, "me/repo"))
			assert.is_true(remotes.same_repository(assert(remote("origin", "me/repo").target), "me/repo"))
			assert.is_false(remotes.same_repository(assert(remote("fork", "me/repo").target), "parent/repo"))
		end)
	end)

	describe("head_remote", function()
		it("prefers origin and otherwise uses the first remote", function()
			assert.equal("origin", assert(remotes.head_remote({ remote("fork"), remote("origin") })).name)
			assert.equal("fork", assert(remotes.head_remote({ remote("fork"), remote("other") })).name)
		end)

		it("uses the pushed remote before origin", function()
			local value = remotes.head_remote({
				remote("origin", "me/repo"),
				remote("fork", "me/repo"),
			}, "fork")

			assert.equal("fork", assert(value).name)
		end)

		it("requires at least one remote", function()
			local value, err = remotes.head_remote({})
			assert.is_nil(value)
			assert.matches("No Git remotes configured", assert(err), 1, true)
		end)
	end)

	describe("validate", function()
		it("accepts matching providers and hosts", function()
			assert.is_nil(remotes.validate(remote("origin", "me/repo"), remote("upstream", "parent/repo")))
		end)

		it("rejects mismatched providers or hosts", function()
			local err = remotes.validate(
				remote("origin", "me/repo", "github", "github.com"),
				remote("upstream", "parent/repo", "gitlab", "gitlab.com")
			)
			assert.matches("different providers", assert(err), 1, true)

			err = remotes.validate(
				remote("origin", "me/repo", "github", "github.com"),
				remote("upstream", "parent/repo", "github", "github.example.com")
			)
			assert.matches("different providers", assert(err), 1, true)
		end)

		it("allows unresolved targets", function()
			assert.is_nil(remotes.validate(remote("origin"), remote("upstream", "parent/repo")))
		end)
	end)

	describe("compatible_remotes", function()
		it("keeps supported remotes on the same provider and host", function()
			local origin = remote("origin", "me/repo")
			local compatible = remotes.compatible_remotes({
				origin,
				remote("upstream", "parent/repo"),
				remote("mirror", "mirror/repo", "gitlab", "gitlab.com"),
				remote("unsupported"),
			}, origin)

			assert.same(
				{ "origin", "upstream" },
				vim.tbl_map(function(item)
					return item.name
				end, compatible)
			)
		end)
	end)

	describe("branch_options", function()
		local origin = remote("origin", "me/repo")
		local upstream = remote("upstream", "parent/repo")
		local branches = {
			origin = { "feature", "main" },
			upstream = { "dev", "feature", "main" },
		}

		it("qualifies branches with their remote", function()
			local options = remotes.branch_options(branches, { origin, upstream }, "origin", "topic", origin.target)

			assert.same(
				{ "origin/feature", "origin/main", "upstream/dev", "upstream/feature", "upstream/main" },
				vim.tbl_map(function(option)
					return option.label
				end, options)
			)
		end)

		it("excludes the head branch only from the head repository", function()
			local options = remotes.branch_options(branches, { origin, upstream }, "origin", "feature", origin.target)

			assert.same(
				{ "origin/main", "upstream/dev", "upstream/feature", "upstream/main" },
				vim.tbl_map(function(option)
					return option.label
				end, options)
			)
		end)

		it("uses the remote target for each option", function()
			local options = remotes.branch_options(branches, { upstream }, "origin", "topic", origin.target)

			assert.equal("parent/repo", options[1].target.repo_full_name)
		end)
	end)

	describe("base_branch", function()
		it("prefers the remote default when it is fetched", function()
			assert.equal("dev", remotes.base_branch({ "dev", "main" }, "dev", "topic", false))
		end)

		it("falls back to a common default branch", function()
			assert.equal("dev", remotes.base_branch({ "dev", "feat/x" }, "main", "topic", false))
			assert.equal("main", remotes.base_branch({ "main", "feat/x" }, "missing", "topic", false))
		end)

		it("skips the head branch in the same repository", function()
			assert.equal("develop", remotes.base_branch({ "feature", "develop" }, "feature", "feature", true))
		end)

		it("returns nil when there is no usable local branch", function()
			assert.is_nil(remotes.base_branch({}, nil, "topic", false))
		end)
	end)

	describe("ensure_branch_option", function()
		it("inserts a missing option once", function()
			local origin = remote("origin", "me/repo")
			local options = remotes.ensure_branch_option({}, origin, "main")
			options = remotes.ensure_branch_option(options, origin, "main")

			assert.equal(1, #options)
			assert.equal("origin/main", options[1].label)
		end)
	end)

	describe("head_ref", function()
		it("qualifies branches from another repository with the owner", function()
			assert.equal("me:feature", remotes.head_ref("parent/repo", "me/repo", "feature"))
		end)

		it("keeps the branch name for the same or an unknown repository", function()
			assert.equal("feature", remotes.head_ref("parent/repo", "parent/repo", "feature"))
			assert.equal("feature", remotes.head_ref("parent/repo", nil, "feature"))
		end)
	end)
end)
