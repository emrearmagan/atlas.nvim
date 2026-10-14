local MODULE = "atlas.providers.shortcut.client"

describe("Shortcut client", function()
	local saved, modules, client, token, request

	before_each(function()
		token = "shortcut-test-token"
		request = nil
		modules = {
			["atlas.config"] = {
				provider_options = function()
					return { token = token }
				end,
			},
			["atlas.core.http"] = {
				curl_request = function(method, url, headers, body, callback)
					request = { method = method, url = url, headers = headers, body = body, callback = callback }
					return { cancel = function() end }
				end,
			},
			["atlas.core.logger"] = { loginfo = function() end, logerror = function() end },
		}
		saved = { [MODULE] = package.loaded[MODULE] }
		for name, module in pairs(modules) do
			saved[name], package.loaded[name] = package.loaded[name], module
		end
		package.loaded[MODULE] = nil
		client = require(MODULE)
	end)

	after_each(function()
		package.loaded[MODULE] = saved[MODULE]
		for name in pairs(modules) do
			package.loaded[name] = saved[name]
		end
	end)

	it("sends authenticated requests to Shortcut", function()
		client.request("POST", "/stories", { name = "Story" }, function() end)

		assert.equal("POST", request.method)
		assert.equal("https://api.app.shortcut.com/api/v3/stories", request.url)
		assert.equal(token, request.headers["Shortcut-Token"])
		assert.equal('{"name":"Story"}', request.body)
	end)

	it("requires a token", function()
		token = nil
		local error
		client.request("GET", "/member", nil, function(_, value)
			error = value
		end)

		assert.is_nil(request)
		assert.matches("Missing Shortcut token", error)
	end)

	it("reports HTTP and malformed-response errors", function()
		for _, response in ipairs({
			{ error = "HTTP 429" },
			{ body = "unexpected", error = nil },
		}) do
			local result, err
			client.request("GET", "/member", nil, function(value, error)
				result, err = value, error
			end)
			request.callback(response.body, response.error)
			assert.is_nil(result)
			assert.is_string(err)
		end
	end)
end)
