describe("ui.window_options", function()
	local window_options
	local autocmds
	local originals

	before_each(function()
		originals = {
			create_augroup = vim.api.nvim_create_augroup,
			create_autocmd = vim.api.nvim_create_autocmd,
			nvim_buf_is_valid = vim.api.nvim_buf_is_valid,
			nvim_buf_get_name = vim.api.nvim_buf_get_name,
			nvim_get_option_value = vim.api.nvim_get_option_value,
			nvim_set_option_value = vim.api.nvim_set_option_value,
			win_findbuf = vim.fn.win_findbuf,
			bo = rawget(vim, "bo"),
			wo = rawget(vim, "wo"),
			list = vim.o.list,
		}
		autocmds = {}
		vim.api.nvim_create_augroup = function()
			return 1
		end
		vim.api.nvim_create_autocmd = function(events, opts)
			table.insert(autocmds, { events = events, opts = opts })
			return 1
		end
		vim.api.nvim_buf_is_valid = function(buf)
			return buf == 10 or buf == 11
		end
		vim.api.nvim_buf_get_name = function(buf)
			return buf == 10 and "atlas://logs" or "/tmp/file.lua"
		end
		vim.fn.win_findbuf = function()
			return { 1 }
		end
		vim.api.nvim_get_option_value = function(name, opts)
			assert.are.equal("list", name)
			assert.are.equal("global", opts.scope)
			return true
		end
		vim.api.nvim_set_option_value = function(name, value, opts)
			assert.are.equal("list", name)
			assert.are.equal("local", opts.scope)
			vim.wo[opts.win].list = value
		end
		vim.bo = {
			[10] = { filetype = "atlas-ui.logs" },
			[11] = { filetype = "lua" },
		}
		vim.wo = {
			[1] = { list = true },
			[2] = { list = false },
		}
		vim.o.list = true
		package.loaded["atlas.ui.window_options"] = nil
		window_options = require("atlas.ui.window_options")
	end)

	after_each(function()
		vim.api.nvim_create_augroup = originals.create_augroup
		vim.api.nvim_create_autocmd = originals.create_autocmd
		vim.api.nvim_buf_is_valid = originals.nvim_buf_is_valid
		vim.api.nvim_buf_get_name = originals.nvim_buf_get_name
		vim.api.nvim_get_option_value = originals.nvim_get_option_value
		vim.api.nvim_set_option_value = originals.nvim_set_option_value
		vim.fn.win_findbuf = originals.win_findbuf
		vim.bo = originals.bo
		vim.wo = originals.wo
		vim.o.list = originals.list
	end)

	---@return table
	local function buffer_autocmd()
		return autocmds[1]
	end

	it("listens for Atlas windows", function()
		window_options.setup()

		assert.are.same({ "BufWinEnter", "WinEnter" }, buffer_autocmd().events)
		assert.are.equal("Hide listchars in Atlas UI windows", buffer_autocmd().opts.desc)
	end)

	it("disables list for Atlas buffers", function()
		window_options.setup()
		buffer_autocmd().opts.callback({ buf = 10 })

		assert.is_false(vim.wo[1].list)
	end)

	it("matches the Atlas filetype when the buffer name is not set", function()
		vim.api.nvim_buf_get_name = function()
			return ""
		end
		window_options.setup()
		buffer_autocmd().opts.callback({ buf = 10 })

		assert.is_false(vim.wo[1].list)
	end)

	it("restores list when the window shows a regular buffer again", function()
		window_options.setup()
		buffer_autocmd().opts.callback({ buf = 10 })
		buffer_autocmd().opts.callback({ buf = 11 })

		assert.is_true(vim.wo[1].list)
	end)

	it("leaves windows it never changed alone", function()
		vim.fn.win_findbuf = function()
			return { 2 }
		end
		window_options.setup()
		buffer_autocmd().opts.callback({ buf = 11 })

		assert.is_false(vim.wo[2].list)
	end)

	it("ignores invalid buffers", function()
		window_options.setup()
		buffer_autocmd().opts.callback({ buf = 99 })

		assert.is_true(vim.wo[1].list)
	end)
end)
