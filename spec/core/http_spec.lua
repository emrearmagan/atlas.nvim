describe("core.http", function()
	local original_vim, original_module, original_preload

	before_each(function()
		original_vim = vim
		original_module = package.loaded["atlas.core.http"]
		original_preload = package.preload["atlas.core.http"]
		package.loaded["atlas.core.http"] = nil
		package.preload["atlas.core.http"] = nil
	end)

	after_each(function()
		_G.vim = original_vim
		package.loaded["atlas.core.http"] = original_module
		package.preload["atlas.core.http"] = original_preload
	end)

	it("runs at most ten requests at once and completes the queue", function()
		local jobs, handles = {}, {}
		local completed = 0
		_G.vim = vim.tbl_extend("force", vim, {
			fn = {
				jobstart = function(_, opts)
					table.insert(jobs, opts)
					return #jobs
				end,
				chansend = function(_, data)
					return #data
				end,
				chanclose = function() end,
			},
		})
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
			jobs[i].on_stdout(i, { "__ATLAS_HTTP_CODE:200" })
			jobs[i].on_exit(i, 0)
			assert.equal(math.min(12, i + 10), #jobs)
		end
		assert.equal(12, completed)
	end)
end)
