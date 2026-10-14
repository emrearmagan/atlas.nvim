local config = require("atlas.config")

describe("Azure client HTTP contract", function()
	local original_options, original_vim, original_http, original_client
	local original_logger
	local response, response_error, status, headers, captured

	before_each(function()
		original_options = config.options
		original_vim = vim
		original_http = package.loaded["atlas.core.http"]
		original_client = package.loaded["atlas.providers.azure.client"]
		original_logger = package.loaded["atlas.core.logger"]
		package.loaded["atlas.core.logger"] = { loginfo = function() end, logerror = function() end }
		config.options = { providers = { azure = { base_url = "https://dev.azure.com/acme/", token = "test-token" } } }
		_G.vim = vim.tbl_extend("force", vim, {
			fn = vim.tbl_extend("force", vim.fn, { json_encode = vim.json.encode }),
			base64 = {
				encode = function(value)
					assert.equal(":test-token", value)
					return "test-encoded"
				end,
			},
		})
		response, response_error, status, headers = { value = {} }, nil, 200, { ["x-ms-continuationtoken"] = "next" }
		package.loaded["atlas.core.http"] = {
			curl_request = function(method, url, request_headers, body, callback)
				captured = { method = method, url = url, headers = request_headers, body = body }
				callback(response, response_error, status, headers)
			end,
		}
		package.loaded["atlas.providers.azure.client"] = nil
	end)

	after_each(function()
		config.options = original_options
		_G.vim = original_vim
		package.loaded["atlas.core.http"] = original_http
		package.loaded["atlas.providers.azure.client"] = original_client
		package.loaded["atlas.core.logger"] = original_logger
	end)

	it("passes continuation headers after the shared status argument", function()
		local received
		require("atlas.providers.azure.client").request(
			"GET",
			"/_apis/git/repositories?top=1",
			nil,
			function(result, err, metadata)
				received = metadata
				assert.equal(response, result)
				assert.is_nil(err)
			end
		)
		assert.equal(headers, received)
		assert.equal("https://dev.azure.com/acme/_apis/git/repositories?top=1&api-version=7.1", captured.url)
		assert.equal("Basic test-encoded", captured.headers.Authorization)
	end)

	it("retains version overrides, patch content type and transport errors", function()
		response, response_error, status = nil, "HTTP 400", 400
		local received_error
		require("atlas.providers.azure.client").request("PATCH", "/_apis/wit/workitems/42", {}, function(result, err)
			received_error = err
			assert.is_nil(result)
		end, nil, "7.1-preview.4", "application/json-patch+json")
		assert.equal("HTTP 400", received_error)
		assert.equal("PATCH", captured.method)
		assert.equal("application/json-patch+json", captured.headers["Content-Type"])
		assert.equal("https://dev.azure.com/acme/_apis/wit/workitems/42?api-version=7.1-preview.4", captured.url)
	end)
end)
