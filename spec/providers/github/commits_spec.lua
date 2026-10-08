local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.changes"] = nil
	return require("atlas.pulls.providers.github.api.changes")
end

local function stub_client(gh)
	github_client.install({ gh = gh })
end

local function commit_page(commits)
	local nodes = {}
	for _, commit in ipairs(commits) do
		table.insert(nodes, { commit = commit })
	end
	return { data = { repository = { pullRequest = { commits = { nodes = nodes } } } } }
end

describe("github pulls.fetch_commits", function()
	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.changes"] = nil
	end)

	it("fails fast when the PR has no repo_full_name", function()
		local calls = 0
		stub_client(function()
			calls = calls + 1
		end)
		local api = fresh_module()

		local pr = { id = 1, repo_full_name = "" }
		local commits, err
		api.fetch_commits(pr, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("Missing repo", err)
		assert.equal(0, calls)
	end)

	it("keeps full messages and newest-first order across all commit pages", function()
		stub_client(function(args, callback)
			assert.is_truthy(table.concat(args, " "):find("--paginate", 1, true))
			assert.is_truthy(table.concat(args, " "):find("--slurp", 1, true))
			callback({
				commit_page({
					{
						oid = "abc123def456",
						messageHeadline = "Fix bug",
						messageBody = "This explains why the fix is needed.\nSecond body line.",
						authors = { nodes = { { name = "Alice", user = { login = "alice" } } } },
						authoredDate = "2024-01-02T03:04:05Z",
					},
					{ oid = "def456", messageHeadline = "Headline only", messageBody = "" },
				}),
				commit_page({ { oid = "ghi789", messageHeadline = "", messageBody = "Body only" } }),
			}, nil)
		end)
		local api = fresh_module()

		local pr = { id = 42, repo_full_name = "octo/repo" }
		local commits
		api.fetch_commits(pr, nil, function(c)
			commits = c
		end)

		assert.equal(3, #commits)
		assert.equal("Fix bug\n\nThis explains why the fix is needed.\nSecond body line.", commits[3].message)
		assert.equal("abc123def456", commits[3].hash)
		assert.equal("abc123d", commits[3].short_hash)
		assert.equal("alice", commits[3].author_nickname)
		assert.equal("Headline only", commits[2].message)
		assert.equal("Body only", commits[1].message)
	end)

	it("propagates errors from the gh CLI", function()
		stub_client(function(_, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local pr = { id = 42, repo_full_name = "octo/repo" }
		local commits, err
		api.fetch_commits(pr, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("boom", err)
	end)
end)
