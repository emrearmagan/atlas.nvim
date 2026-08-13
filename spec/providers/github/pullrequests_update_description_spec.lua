local github_client = require("spec.support.github_client_stub")

local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	return require("atlas.pulls.providers.github.api.pullrequests")
end

local function stub_client(gh)
	github_client.install({ gh = gh })
end

describe("github pullrequests.update_description", function()
	local calls

	before_each(function()
		calls = {}
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	end)

	after_each(function()
		github_client.uninstall()
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	end)

	it("fails fast when the PR has no repo_full_name", function()
		stub_client(function(args, callback)
			table.insert(calls, args)
			callback(nil, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = 42, repo_full_name = "" }, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("Missing repo", err)
		assert.equal(0, #calls)
	end)

	it("runs gh pr edit with the new body", function()
		stub_client(function(args, callback)
			table.insert(calls, args)
			callback(nil, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = 42, repo_full_name = "octo/repo" }, "Line one\nLine two", function(success, e)
			ok, err = success, e
		end)

		assert.is_true(ok)
		assert.is_nil(err)
		assert.equal(1, #calls)
		assert.same({ "pr", "edit", "42", "--repo", "octo/repo", "--body", "Line one\nLine two" }, calls[1])
	end)

	it("clears an empty description", function()
		stub_client(function(args, callback)
			table.insert(calls, args)
			callback(nil, nil)
		end)
		local api = fresh_module()

		local ok
		api.update_description({ id = 42, repo_full_name = "octo/repo" }, "", function(success)
			ok = success
		end)

		assert.is_true(ok)
		assert.same({ "pr", "edit", "42", "--repo", "octo/repo", "--body", "" }, calls[1])
	end)

	it("propagates errors from the gh CLI", function()
		stub_client(function(_, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = 42, repo_full_name = "octo/repo" }, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
	end)
end)
