local function fresh_module()
	package.loaded["atlas.pulls.providers.bitbucket.api.pullrequests"] = nil
	return require("atlas.pulls.providers.bitbucket.api.pullrequests")
end

local function stub_service(request, clear_cache)
	package.preload["atlas.pulls.providers.bitbucket.api.service"] = function()
		return {
			request = request,
			clear_cache = clear_cache or function() end,
		}
	end
end

describe("bitbucket pull request updates", function()
	local calls
	local cache_cleared

	before_each(function()
		calls = {}
		cache_cleared = 0
		package.loaded["atlas.pulls.providers.bitbucket.api.service"] = nil
	end)

	after_each(function()
		package.preload["atlas.pulls.providers.bitbucket.api.service"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.service"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.pullrequests"] = nil
	end)

	it("fails fast when the PR has no self link", function()
		stub_service(function(method, url, headers, body, callback)
			table.insert(calls, { method = method, url = url, headers = headers, body = body })
			callback({}, nil)
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = 5, _raw = { links = {} } }, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("No pull request URL available", err)
		assert.equal(0, #calls)
	end)

	it("PUTs title and description fields to the PR's self link", function()
		stub_service(function(method, url, headers, body, callback)
			table.insert(calls, { method = method, url = url, headers = headers, body = body })
			callback({}, nil)
		end, function()
			cache_cleared = cache_cleared + 1
		end)
		local api = fresh_module()
		local pr = {
			id = 5,
			_raw = { links = { self = "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5" } },
		}

		api.update_title(pr, "New title", function(success, err)
			assert.is_true(success)
			assert.is_nil(err)
		end)
		api.update_description(pr, "New body", function(success, err)
			assert.is_true(success)
			assert.is_nil(err)
		end)

		assert.equal(2, #calls)
		assert.equal("PUT", calls[1].method)
		assert.equal("https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5", calls[1].url)
		assert.equal('{"title":"New title"}', calls[1].body)
		assert.equal('{"description":"New body"}', calls[2].body)
		assert.equal(2, cache_cleared)
	end)

	it("propagates errors from the request", function()
		stub_service(function(_, _, _, _, callback)
			callback(nil, "boom")
		end)
		local api = fresh_module()

		local ok, err
		api.update_description({ id = 5, _raw = { links = { self = "url" } } }, "New body", function(success, e)
			ok, err = success, e
		end)

		assert.is_false(ok)
		assert.equal("boom", err)
	end)
end)
