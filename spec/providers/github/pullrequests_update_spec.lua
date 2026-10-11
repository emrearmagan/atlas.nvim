local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	return require("atlas.pulls.providers.github.api.pullrequests")
end

describe("github pull request updates", function()
	local calls
	local reviews_module

	before_each(function()
		calls = {}
		reviews_module = package.loaded["atlas.pulls.providers.github.api.reviews"]
	end)

	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
		package.loaded["atlas.pulls.providers.github.api.reviews"] = reviews_module
	end)

	it("fails fast when the PR has no repo_full_name", function()
		github_client.install({
			gh = function(args, callback)
				table.insert(calls, args)
				callback(nil, nil)
			end,
		})
		local api = fresh_module()

		for action, value in pairs({ update_title = "New title", update_description = "New body" }) do
			local ok, err
			api[action]({ id = 42, repo_full_name = "" }, value, function(success, e)
				ok, err = success, e
			end)
			assert.is_false(ok)
			assert.equal("Missing repo", err)
		end
		assert.equal(0, #calls)
	end)

	it("runs gh pr edit with title, multiline body and empty body updates", function()
		github_client.install({
			gh = function(args, callback)
				table.insert(calls, args)
				callback(nil, nil)
			end,
		})
		local api = fresh_module()

		local pr = { id = 42, repo_full_name = "octo/repo" }
		for index, case in ipairs({
			{ "update_title", "--title", "New title" },
			{ "update_description", "--body", "Line one\nLine two" },
			{ "update_description", "--body", "" },
		}) do
			local ok, err
			api[case[1]](pr, case[3], function(success, e)
				ok, err = success, e
			end)
			assert.is_true(ok)
			assert.is_nil(err)
			assert.same({ "pr", "edit", "42", "--repo", "octo/repo", case[2], case[3] }, calls[index])
		end
		assert.equal(3, #calls)
	end)

	it("passes merge messages to gh", function()
		github_client.install({
			gh = function(args, callback)
				table.insert(calls, args)
				callback(nil, nil)
			end,
		})
		local api = fresh_module()
		local pr = { id = 42, repo_full_name = "octo/repo" }
		for index, case in ipairs({ { method = "merge", body = "Body" }, { method = "squash", body = "" } }) do
			api.merge(pr, {
				method = case.method,
				delete_source_branch = true,
				subject = "Subject",
				body = case.body,
			}, function() end)
			assert.same({
				"pr",
				"merge",
				"42",
				"--repo",
				"octo/repo",
				"--" .. case.method,
				"--delete-branch",
				"--subject",
				"Subject",
				"--body",
				case.body,
			}, calls[index])
		end
	end)

	it("propagates errors from the gh CLI", function()
		github_client.install({
			gh = function(_, callback)
				callback(nil, "boom")
			end,
		})
		local api = fresh_module()

		for action, value in pairs({ update_title = "New title", update_description = "New body" }) do
			local ok, err
			api[action]({ id = 42, repo_full_name = "octo/repo" }, value, function(success, e)
				ok, err = success, e
			end)
			assert.is_false(ok)
			assert.equal("boom", err)
		end
	end)

	it("clears supplied empty selections and leaves omitted fields alone", function()
		github_client.install({
			gh = function(args, callback)
				calls[#calls + 1] = args
				callback(nil, nil)
			end,
		})
		local api = fresh_module()
		local pr = { id = 42, repo_full_name = "octo/repo" }
		api.update_pr(pr, { labels = {} }, function() end)
		api.update_pr(pr, { assignees = {} }, function() end)

		assert.same({
			{ "api", "-X", "PATCH", "repos/octo/repo/issues/42", "-f", "labels[]" },
			{ "api", "-X", "PATCH", "repos/octo/repo/issues/42", "-f", "assignees[]" },
		}, calls)
	end)

	it("fetches current reviewers without requesting retained reviewers again", function()
		github_client.install({
			gh = function(args, callback)
				calls[#calls + 1] = args
				callback(nil, nil)
			end,
		})
		package.loaded["atlas.pulls.providers.github.api.reviews"] = {
			fetch_reviewers = function(_, opts, done)
				assert.is_true(opts.force_refresh)
				done({
					{ name = "Alice", username = "alice", role = "reviewer", decision = "approved" },
					{ name = "Bob", username = "bob", role = "reviewer", decision = "pending" },
					{ name = "Dan", username = "dan", role = "participant", decision = "reviewed" },
				}, nil)
			end,
		}
		local api = fresh_module()
		local pr = { id = 42, repo_full_name = "octo/repo" }
		local ok
		api.update_pr(pr, {
			reviewers = { { label = "@alice", provider_id = "alice" }, { label = "@carol", provider_id = "carol" } },
		}, function(success)
			ok = success
		end)

		assert.is_true(ok)
		assert.same({
			{ "pr", "edit", "42", "--repo", "octo/repo", "--add-reviewer", "carol", "--remove-reviewer", "bob" },
		}, calls)
	end)
end)
