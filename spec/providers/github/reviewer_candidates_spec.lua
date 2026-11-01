local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	return require("atlas.pulls.providers.github.api.pullrequests")
end

describe("github reviewer candidates", function()
	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	end)

	it("explains collaborator permission errors without failing", function()
		local calls = {}
		github_client.install({
			gh = function(args, callback)
				table.insert(calls, args)
				callback(nil, "gh: Must have push access to view repository collaborators. (HTTP 403)")
			end,
		})
		local api = fresh_module()

		local reviewers, failure
		api.fetch_reviewer_candidates({ repo_slug = "parent/repo" }, function(items, err)
			reviewers, failure = items, err
		end)

		assert.is_nil(reviewers)
		assert.equal("Reviewer suggestions require push access to parent/repo", failure)
		assert.same({
			"api",
			"--paginate",
			"--slurp",
			"repos/parent/repo/collaborators?per_page=100",
		}, calls[1])
	end)
end)
