local function fresh_module()
	package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	return require("atlas.pulls.providers.github.api.pullrequests")
end

local function stub_client(gh)
	package.preload["atlas.providers.github.client"] = function()
		local client = {
			gh = gh,
			get_mem = function()
				return nil, false
			end,
			set_mem = function() end,
		}
		return { pulls = client, issues = client }
	end
end

describe("github pullrequests.update_title", function()
	local calls

	before_each(function()
		calls = {}
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
		package.loaded["atlas.providers.github.client"] = nil
	end)

	after_each(function()
		package.preload["atlas.providers.github.client"] = nil
		package.loaded["atlas.providers.github.client"] = nil
		package.loaded["atlas.pulls.providers.github.api.pullrequests"] = nil
	end)

	it("fails fast when the PR has no repo_full_name", function()
		stub_client(function(args, callback)
			table.insert(calls, args)
			callback(nil, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_title({ id = 42, repo_full_name = "" }, "New title", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("Missing repo", err)
		assert.equal(0, #calls)
	end)

	it("runs gh pr edit with the new title", function()
		stub_client(function(args, callback)
			table.insert(calls, args)
			callback(nil, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_title({ id = 42, repo_full_name = "octo/repo" }, "New title", function(success, e)
			ok, err = success, e
		end)

		assert.is_true(ok)
		assert.is_nil(err)
		assert.equal(1, #calls)
		assert.same({ "pr", "edit", "42", "--repo", "octo/repo", "--title", "New title" }, calls[1])
	end)

	it("propagates errors from the gh CLI", function()
		stub_client(function(_, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local ok, err
		api.update_title({ id = 42, repo_full_name = "octo/repo" }, "New title", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
	end)
end)
