local git = require("atlas.core.git")

describe("core.git remotes", function()
	local original_run

	before_each(function()
		original_run = git.run
	end)

	after_each(function()
		git.run = original_run
	end)

	---@param stdout string
	---@return { cancel: fun() }
	local function complete(stdout, done)
		done({ code = 0, stdout = stdout, stderr = "" })
		return {
			cancel = function() end,
		}
	end

	it("lists fetch remotes and resolves their repository targets", function()
		git.run = function(args, _, done)
			assert.same({ "-C", "/repo", "remote", "-v" }, args)
			return complete(
				"origin\thttps://github.com/me/repo.git (fetch)\n"
					.. "origin\thttps://github.com/me/repo.git (push)\n"
					.. "upstream\tgit@github.com:parent/repo.git (fetch) [blob:none]\n"
					.. "mirror\thttps://example.com/mirror/repo.git (fetch)\n",
				done
			)
		end

		local remotes
		git.list_repository_remotes("/repo", function(value)
			remotes = value
		end)

		assert.equal(3, #remotes)
		assert.equal("origin", remotes[1].name)
		assert.equal("me/repo", remotes[1].target.repo_full_name)
		assert.equal("upstream", remotes[2].name)
		assert.equal("parent/repo", remotes[2].target.repo_full_name)
		assert.is_nil(remotes[3].target)
	end)

	it("lists branches for every remote", function()
		git.run = function(args, _, done)
			assert.same({ "-C", "/repo", "branch", "-r", "--format=%(refname:short)" }, args)
			return complete("origin/main\norigin/feature/x\nupstream\nupstream/dev\nupstream/HEAD\n", done)
		end

		local branches
		git.list_all_remote_branches("/repo", { "origin", "upstream" }, function(value)
			branches = value
		end)

		assert.same({ "main", "feature/x" }, branches.origin)
		assert.same({ "dev" }, branches.upstream)
	end)
end)
