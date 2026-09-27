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

	it("PUTs descriptions including an empty body and accepts empty responses", function()
		local response
		stub_service(function(method, endpoint, payload, callback)
			table.insert(calls, { method = method, endpoint = endpoint, payload = payload })
			callback(response, nil)
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project" }

		for index, case in ipairs({
			{ body = "New body", response = { iid = 12, description = "Normalized by GitLab" } },
			{ body = "New body" },
			{ body = "", response = { iid = 12, description = "" } },
		}) do
			response = case.response
			local ok, err
			api.update_description(pr, case.body, function(success, e)
				ok, err = success, e
			end)
			assert.is_true(ok)
			assert.is_nil(err)
			assert.same({
				method = "PUT",
				endpoint = "/projects/group%2Fproject/merge_requests/12",
				payload = { description = case.body },
			}, calls[index])
		end
		assert.equal(3, #calls)
	end)

	it("propagates errors from the request", function()
		stub_service(function(_, _, _, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()
		local pr = { id = 12, repo_full_name = "group/project" }

		local ok, err
		api.update_description(pr, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
	end)
end)
