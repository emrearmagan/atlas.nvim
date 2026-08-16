local cache_cleared

local function fresh_module()
	package.loaded["atlas.pulls.providers.bitbucket.api.pullrequests"] = nil
	package.loaded["atlas.pulls.providers.bitbucket.api.cloud.pullrequests"] = nil
	package.loaded["atlas.pulls.providers.bitbucket.api.server.pullrequests"] = nil
	package.loaded["atlas.pulls.providers.bitbucket.api.router"] = nil
	return require("atlas.pulls.providers.bitbucket.api.pullrequests")
end

local function stub_service(request, api_type)
	package.preload["atlas.pulls.providers.bitbucket.api.service"] = function()
		return {
			api_type = function()
				return api_type or "cloud"
			end,
			request = request,
			clear_cache = function()
				cache_cleared = cache_cleared + 1
			end,
		}
	end
end

describe("bitbucket pull request updates", function()
	local calls
	local json_encode

	before_each(function()
		calls = {}
		cache_cleared = 0
		json_encode = vim.json.encode
		package.loaded["atlas.pulls.providers.bitbucket.api.service"] = nil
	end)

	after_each(function()
		vim.json.encode = json_encode
		package.preload["atlas.pulls.providers.bitbucket.api.service"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.service"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.router"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.cloud.pullrequests"] = nil
		package.loaded["atlas.pulls.providers.bitbucket.api.server.pullrequests"] = nil
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
		package.preload["atlas.pulls.providers.bitbucket.api.service"] = function()
			return {
				api_type = function()
					return "cloud"
				end,
				request = function(method, url, headers, body, callback)
					table.insert(calls, { method = method, url = url, headers = headers, body = body })
					callback({}, nil)
				end,
				clear_cache = function()
					cache_cleared = cache_cleared + 1
				end,
			}
		end
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

	it("updates Bitbucket Server pull requests", function()
		local bodies = {}
		vim.json.encode = function(value)
			table.insert(bodies, value)
			return "encoded"
		end
		stub_service(function(method, url, headers, body, callback)
			table.insert(calls, { method = method, url = url, headers = headers, body = body })
			callback({ version = 7 + #calls }, nil)
		end, "server")
		local api = fresh_module()
		local pr = {
			id = 5,
			workspace = "ATLAS",
			repo = "atlas.nvim",
			_raw = { version = 7 },
		}

		api.update_title(pr, "New title", function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)
		api.update_description(pr, "New body", function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)
		api.update_reviewers(pr, { { provider_id = "alice" } }, {}, function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)
		api.decline(pr, function(ok, err)
			assert.is_true(ok)
			assert.is_nil(err)
		end)
		assert.equal(4, #calls)
		assert.equal("PUT", calls[1].method)
		assert.equal("/projects/ATLAS/repos/atlas.nvim/pull-requests/5", calls[1].url)
		assert.same({ title = "New title", version = 7 }, bodies[1])
		assert.same({ description = "New body", version = 8 }, bodies[2])
		assert.same({ reviewers = { { user = { name = "alice" } } }, version = 9 }, bodies[3])
		assert.equal("POST", calls[4].method)
		assert.equal("/projects/ATLAS/repos/atlas.nvim/pull-requests/5/decline?version=10", calls[4].url)
		assert.is_nil(calls[4].body)
		assert.equal(11, pr._raw.version)
		assert.equal(4, cache_cleared)
	end)
end)
