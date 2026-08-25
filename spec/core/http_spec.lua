describe("HTTP", function()
	local original

	before_each(function()
		original = {
			jobstart = vim.fn.jobstart,
			chansend = vim.fn.chansend,
			chanclose = vim.fn.chanclose,
			decode = vim.json.decode,
		}
		package.loaded["atlas.core.http"] = nil
	end)

	after_each(function()
		vim.fn.jobstart = original.jobstart
		vim.fn.chansend = original.chansend
		vim.fn.chanclose = original.chanclose
		vim.json.decode = original.decode
		package.loaded["atlas.core.http"] = nil
	end)

	it("keeps credentials and request bodies out of curl arguments", function()
		local args
		local job_opts
		local config_input
		vim.fn.jobstart = function(command, opts)
			args = command
			job_opts = opts
			return 23
		end
		vim.fn.chansend = function(job_id, input)
			assert.equal(23, job_id)
			config_input = input
		end
		vim.fn.chanclose = function(job_id, stream)
			assert.equal(23, job_id)
			assert.equal("stdin", stream)
		end
		vim.json.decode = function()
			return { ok = true }
		end

		local result
		require("atlas.core.http").curl_request(
			"POST",
			"https://git.example/api",
			{ Authorization = "token secret" },
			'{"body":"private"}',
			function(value)
				result = value
			end
		)

		assert.same({ "curl", "--config", "-" }, args)
		assert.is_nil(table.concat(args, " "):find("secret", 1, true))
		assert.is_nil(table.concat(args, " "):find("private", 1, true))
		assert.is_truthy(config_input:find('header = "Authorization: token secret"', 1, true))
		assert.is_truthy(config_input:find('data-raw = "{\\"body\\":\\"private\\"}"', 1, true))

		job_opts.on_stdout(23, { '{"ok":true}__ATLAS_HTTP_CODE:200' })
		job_opts.on_exit(23, 0)
		assert.is_true(result.ok)
		assert.equal(200, result.__http_status)
	end)
end)
