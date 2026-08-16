describe("HTTP", function()
	local original

	before_each(function()
		original = {
			system = vim.system,
			decode = vim.json.decode,
		}
		package.loaded["atlas.core.http"] = nil
		package.loaded["atlas.core.logger"] = nil
		package.preload["atlas.core.logger"] = function()
			return { logerror = function() end }
		end
	end)

	after_each(function()
		vim.system = original.system
		vim.json.decode = original.decode
		package.loaded["atlas.core.http"] = nil
		package.loaded["atlas.core.logger"] = nil
		package.preload["atlas.core.logger"] = nil
	end)

	it("keeps credentials and request bodies out of curl arguments", function()
		local args
		local opts
		local on_exit
		vim.system = function(command, system_opts, callback)
			args = command
			opts = system_opts
			on_exit = callback
			return { pid = 23, kill = function() end }
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
		assert.is_truthy(opts.stdin:find('header = "Authorization: token secret"', 1, true))
		assert.is_truthy(opts.stdin:find('data-raw = "{\\"body\\":\\"private\\"}"', 1, true))

		on_exit({ code = 0, stdout = '{"ok":true}__ATLAS_HTTP_CODE:200', stderr = "" })
		assert.is_true(result.ok)
		assert.equal(200, result.__http_status)
	end)
end)
