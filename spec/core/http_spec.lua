describe("core.http", function()
	local original_vim, original_module, original_preload
	local jobs, command_args, configs, decoded

	before_each(function()
		original_vim = vim
		original_module = package.loaded["atlas.core.http"]
		original_preload = package.preload["atlas.core.http"]
		package.loaded["atlas.core.http"] = nil
		package.preload["atlas.core.http"] = nil
		jobs, command_args, configs = {}, {}, {}
		decoded = { ["{}"] = {} }
		_G.vim = vim.tbl_extend("force", vim, {
			fn = {
				jobstart = function(args, opts)
					table.insert(command_args, args)
					table.insert(jobs, opts)
					return #jobs
				end,
				chansend = function(id, data)
					configs[id] = data
					return #data
				end,
				chanclose = function() end,
			},
			json = {
				decode = function(value)
					assert.is_not_nil(decoded[value], "Unexpected JSON: " .. value)
					return decoded[value]
				end,
			},
		})
	end)

	after_each(function()
		_G.vim = original_vim
		package.loaded["atlas.core.http"] = original_module
		package.preload["atlas.core.http"] = original_preload
	end)

	it("runs at most ten requests at once and completes the queue", function()
		local handles = {}
		local completed = 0
		local http = require("atlas.core.http")
		for i = 1, 12 do
			local fetch = i % 2 == 0 and http.curl_text_request or http.curl_request
			handles[i] = fetch("GET", "https://example.test/" .. i, {}, nil, function(_, err, status)
				assert.is_nil(err)
				assert.equal(200, status)
				completed = completed + 1
			end)
		end

		assert.equal(10, #jobs)
		assert.equal(-1, handles[11].job_id)
		for i = 1, 12 do
			assert.equal(i, handles[i].job_id)
			jobs[i].on_stdout(i, { "__ATLAS_HTTP_CODE:200", "{}" })
			jobs[i].on_exit(i, 0)
			assert.equal(math.min(12, i + 10), #jobs)
		end
		assert.equal(12, completed)
	end)

	it("keeps credentials in stdin and returns status alongside continuation headers", function()
		local http = require("atlas.core.http")
		local body = '{"value":[]}'
		local headers = '{"x-ms-continuationtoken":["next-page"]}'
		decoded[body] = { value = {} }
		decoded[headers] = { ["x-ms-continuationtoken"] = { "next-page" } }
		local result, err, status, response_headers
		http.curl_request(
			"POST",
			"https://example.test/repositories",
			{ Authorization = "Basic secret" },
			body,
			function(...)
				result, err, status, response_headers = ...
			end
		)

		assert.same({ "curl", "--config", "-" }, command_args[1])
		assert.truthy(configs[1]:find('header = "Authorization: Basic secret"', 1, true))
		assert.truthy(configs[1]:find('data-raw = "{\\"value\\":[]}"', 1, true))
		assert.truthy(configs[1]:find('write-out = "__ATLAS_HTTP_CODE:%{http_code}\\n%{header_json}"', 1, true))
		jobs[1].on_stdout(1, { body .. "__ATLAS_HTTP_CODE:200", headers })
		jobs[1].on_exit(1, 0)

		assert.same({ value = {} }, result)
		assert.is_nil(err)
		assert.equal(200, status)
		assert.same({ ["x-ms-continuationtoken"] = "next-page" }, response_headers)
	end)

	it("preserves dev's status argument for empty responses and HTTP errors", function()
		local http = require("atlas.core.http")
		local result, err, status
		local function on_done(...)
			result, err, status = ...
		end
		http.curl_request("DELETE", "https://example.test/item", {}, nil, on_done)
		jobs[1].on_stdout(1, { "__ATLAS_HTTP_CODE:204", "{}" })
		jobs[1].on_exit(1, 0)
		assert.same({}, result)
		assert.is_nil(err)
		assert.equal(204, status)

		http.curl_request("GET", "https://example.test/item", {}, nil, on_done)
		jobs[2].on_stdout(2, { "Forbidden__ATLAS_HTTP_CODE:403", "{}" })
		jobs[2].on_exit(2, 0)
		assert.is_nil(result)
		assert.equal("HTTP 403: Forbidden", err)
		assert.equal(403, status)
	end)

	it("reports invalid header data through the callback", function()
		local http = require("atlas.core.http")
		local result, err, status
		http.curl_request("GET", "https://example.test/item", {}, nil, function(...)
			result, err, status = ...
		end)
		jobs[1].on_stdout(1, { "{}__ATLAS_HTTP_CODE:200", "invalid" })
		jobs[1].on_exit(1, 0)
		assert.is_nil(result)
		assert.equal("Failed to parse HTTP response headers", err)
		assert.equal(200, status)
	end)
end)
