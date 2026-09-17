local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.changes"] = nil
	return require("atlas.pulls.providers.github.api.changes")
end

local function stub_client(gh)
	github_client.install({ gh = gh })
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

		local commits, err
		api.fetch_commits({ id = 1, repo_full_name = "" }, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("Missing repo", err)
		assert.equal(0, calls)
	end)

	it("keeps the full commit body alongside the headline", function()
		stub_client(function(_, callback)
			callback({
				commits = {
					{
						oid = "abc123def456",
						messageHeadline = "Fix bug",
						messageBody = "This explains why the fix is needed.\nSecond body line.",
						authors = { { name = "Alice", login = "alice" } },
						authoredDate = "2024-01-02T03:04:05Z",
					},
				},
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 42, repo_full_name = "octo/repo" }, nil, function(c)
			commits = c
		end)

		assert.equal(1, #commits)
		assert.equal(
			"Fix bug\n\nThis explains why the fix is needed.\nSecond body line.",
			commits[1].message
		)
		assert.equal("abc123def456", commits[1].hash)
		assert.equal("abc123d", commits[1].short_hash)
		assert.equal("alice", commits[1].author_nickname)
	end)

	it("falls back to just the headline when there is no body", function()
		stub_client(function(_, callback)
			callback({
				commits = {
					{ oid = "abc123", messageHeadline = "Fix bug", messageBody = "" },
				},
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 42, repo_full_name = "octo/repo" }, nil, function(c)
			commits = c
		end)

		assert.equal("Fix bug", commits[1].message)
	end)

	it("falls back to just the body when there is no headline", function()
		stub_client(function(_, callback)
			callback({
				commits = {
					{ oid = "abc123", messageHeadline = "", messageBody = "Body only" },
				},
			}, nil)
		end)
		local api = fresh_module()

		local commits
		api.fetch_commits({ id = 42, repo_full_name = "octo/repo" }, nil, function(c)
			commits = c
		end)

		assert.equal("Body only", commits[1].message)
	end)

	it("propagates errors from the gh CLI", function()
		stub_client(function(_, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local commits, err
		api.fetch_commits({ id = 42, repo_full_name = "octo/repo" }, nil, function(c, e)
			commits, err = c, e
		end)

		assert.is_nil(commits)
		assert.equal("boom", err)
	end)
end)
