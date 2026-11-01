local modules = {
	"atlas.providers.azure.client",
	"atlas.providers.azure.users",
	"atlas.providers.azure.repositories",
	"atlas.pulls.providers.azure.api.mapper",
	"atlas.pulls.providers.azure.api.pullrequests",
	"atlas.pulls.providers.azure.api.reviews",
	"atlas.pulls.providers.azure.api.comments",
	"atlas.pulls.providers.azure.api.checks",
	"atlas.pulls.providers.azure.api.changes",
}
local endpoint = "/Platform/_apis/git/repositories/api/pullrequests/1"
local pr = {
	id = 1,
	repo_full_name = "Platform/api",
	repo = { owner = "Platform", repo_name = "api" },
	source = { commit_hash = "head" },
}

describe("Azure pull request API logic", function()
	local saved, client

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name], package.loaded[name] = package.loaded[name], nil
		end
		client = {
			url_encode = require("atlas.core.utils").url_encode,
			build_query = require(modules[1]).build_query,
			get_cache = function() end,
			set_cache = function() end,
			clear_cache = function() end,
		}
		package.loaded[modules[1]] = client
	end)

	after_each(function()
		for _, name in ipairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("maps all pull request commits", function()
		client.fetch_all = function(url, _, _, done)
			assert.equal(endpoint .. "/commits", url)
			done({
				{ commitId = "1", comment = "Commit", author = {} },
				{ commitId = "2", comment = "Commit", author = {} },
			})
		end
		local result
		require("atlas.pulls.providers.azure.api.changes").fetch_commits(pr, {}, function(commits, err)
			assert.is_nil(err)
			result = commits
		end)
		assert.same({ "1", "2" }, { result[1].hash, result[2].hash })
	end)

	it("maps blocking policies to failures and optional policies to warnings", function()
		client.request = function(_, url, _, done)
			assert.equal(
				"/Platform/_apis/policy/evaluations?artifactId=vstfs%3A%2F%2F%2FCodeReview%2FCodeReviewId%2Fproject-id%2F1",
				url
			)
			local policies = {}
			for _, blocking in ipairs({ true, false }) do
				policies[#policies + 1] = {
					status = "rejected",
					configuration = { isBlocking = blocking, type = { displayName = "Policy" }, settings = {} },
				}
			end
			done({ value = policies }, nil)
		end
		local result
		require("atlas.pulls.providers.azure.api.checks").fetch(
			vim.tbl_extend("force", {}, pr, { project_id = "project-id", merge_status = "conflicts" }),
			{},
			function(checks, err)
				assert.is_nil(err)
				result = checks
			end
		)
		assert.same({ "failed", "failed", "warning" }, { result[1].state, result[2].state, result[3].state })
	end)

	it("preserves retained reviewers and sends only additions, removals, and edited fields", function()
		local requests = {}
		client.request = function(method, url, body, done)
			requests[#requests + 1] = { method, url, body }
			if method == "GET" then
				done({ value = { { id = "keep", vote = 10 }, { id = "remove", vote = 0 } } }, nil)
			else
				done({}, nil)
			end
		end
		local updated
		require("atlas.pulls.providers.azure.api.pullrequests").update_pr(vim.deepcopy(pr), {
			title = "Edited",
			body = "Description",
			base = "release",
			draft = false,
			reviewers = { { label = "Keep", provider_id = "keep" }, { label = "Add", provider_id = "add" } },
		}, function(ok, err)
			assert.is_nil(err)
			updated = ok
		end)
		assert.is_true(updated)
		assert.equal(4, #requests)
		assert.same({ "GET", endpoint .. "/reviewers" }, requests[1])
		assert.same({
			"PATCH",
			endpoint,
			{
				title = "Edited",
				description = "Description",
				targetRefName = "refs/heads/release",
				isDraft = false,
			},
		}, requests[4])
		local mutations = {}
		for i = 2, 3 do
			mutations[requests[i][1]] = requests[i]
		end
		assert.same({ "POST", endpoint .. "/reviewers", { { id = "add" } } }, mutations.POST)
		assert.same({ "DELETE", endpoint .. "/reviewers/remove" }, mutations.DELETE)
	end)

	it("does not mutate the PR when loading reviewers fails", function()
		local calls, result = 0, nil
		client.request = function(method, _, _, done)
			calls = calls + 1
			assert.equal("GET", method)
			done(nil, "Unavailable")
		end
		require("atlas.pulls.providers.azure.api.pullrequests").update_pr(
			pr,
			{ reviewers = {}, title = "Edited" },
			function(ok, err)
				result = { ok, err }
			end
		)
		assert.same({ false, "Unavailable" }, result)
		assert.equal(1, calls)
	end)

	it("pins merge requests to the source commit and maps shared completion options", function()
		local payload
		client.request = function(method, url, body, done)
			assert.equal("PATCH", method)
			assert.equal(endpoint, url)
			payload = body
			done({}, nil)
		end
		require("atlas.pulls.providers.azure.api.pullrequests").merge(
			pr,
			{ method = "squash", delete_source_branch = true, subject = "Subject", body = "Body" },
			function() end
		)
		assert.same({
			status = "completed",
			lastMergeSourceCommit = { commitId = "head" },
			completionOptions = {
				mergeStrategy = "squash",
				deleteSourceBranch = true,
				mergeCommitMessage = "Subject\n\nBody",
			},
		}, payload)
	end)
end)
