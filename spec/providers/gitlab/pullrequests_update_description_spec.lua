local module_name = "atlas.pulls.providers.gitlab.api.pullrequests"

local function fresh_module()
	package.loaded[module_name] = nil
	return require(module_name)
end

---@param request fun(method: string, endpoint: string, payload: table|nil, callback: function, ctx: table|nil)
local function stub_service(request)
	package.preload["atlas.providers.gitlab.client"] = function()
		return {
			request = request,
			url_encode = function(value)
				return (tostring(value):gsub("/", "%%2F"))
			end,
			delete_memory_cache = function() end,
		}
	end
end

describe("gitlab pullrequests.update_description", function()
	local calls

	before_each(function()
		calls = {}
		package.loaded[module_name] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
	end)

	after_each(function()
		package.preload["atlas.providers.gitlab.client"] = nil
		package.loaded["atlas.providers.gitlab.client"] = nil
		package.loaded[module_name] = nil
	end)

	it("fails fast when the MR identifier is invalid", function()
		stub_service(function(method, endpoint, payload, callback)
			table.insert(calls, { method = method, endpoint = endpoint, payload = payload })
			callback({}, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = nil, repo_full_name = "group/project" }, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("Invalid MR identifier", err)
		assert.equal(0, #calls)
	end)

	it("PUTs the new description to the merge request endpoint", function()
		stub_service(function(method, endpoint, payload, callback)
			table.insert(calls, { method = method, endpoint = endpoint, payload = payload })
			callback({ iid = 12, description = "Normalized by GitLab" }, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project", description = "Old body" }

		local ok, err
		api.update_description(pr, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_true(ok)
		assert.is_nil(err)
		assert.equal(1, #calls)
		assert.equal("PUT", calls[1].method)
		assert.equal("/projects/group%2Fproject/merge_requests/12", calls[1].endpoint)
		assert.same({ description = "New body" }, calls[1].payload)
		assert.equal("Normalized by GitLab", pr.description)
	end)

	it("falls back to the submitted description when the API returns no body", function()
		stub_service(function(_, _, _, callback)
			callback(nil, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project", description = "Old body" }

		api.update_description(pr, "New body", function() end)

		assert.equal("New body", pr.description)
	end)

	it("clears the description when given an empty body", function()
		stub_service(function(_, _, payload, callback)
			table.insert(calls, { payload = payload })
			callback({ iid = 12, description = "" }, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project", description = "Old body" }

		local ok
		api.update_description(pr, "", function(success)
			ok = success
		end)

		assert.is_true(ok)
		assert.same({ description = "" }, calls[1].payload)
		assert.equal("", pr.description)
	end)

	it("propagates errors from the request", function()
		stub_service(function(_, _, _, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project", description = "Old body" }

		local ok, err
		api.update_description(pr, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
		assert.equal("Old body", pr.description)
	end)
end)
