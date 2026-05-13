local M = {}

---@class AtlasSearchPromptOpts
---@field name string command name used transiently as the cmdline prompt
---@field complete fun(arglead: string, cmdline: string, cursorpos: integer): string[]
---@field on_submit fun(query: string)
---@field default? string text pre-filled into the cmdline after the command name

-- I couldn not get completion to work without a real user command, but I also didn not want every providers prompt command showing up under `:Atlas<Tab>`.
-- This registers the command, feeds the cmdline to it, and deletes it once the cmdline closes.
---@param opts AtlasSearchPromptOpts
function M.open(opts)
	local cmd_name = opts.name
	pcall(vim.api.nvim_del_user_command, cmd_name)

	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		pcall(vim.api.nvim_del_user_command, cmd_name)
	end

	vim.api.nvim_create_user_command(cmd_name, function(cmd_opts)
		cleanup()
		opts.on_submit(cmd_opts.args)
	end, {
		nargs = "*",
		complete = opts.complete,
	})

	vim.api.nvim_create_autocmd("CmdlineLeave", {
		once = true,
		callback = function()
			vim.schedule(cleanup)
		end,
	})

	local default = opts.default and tostring(opts.default) or ""
	local keys = vim.api.nvim_replace_termcodes(":" .. cmd_name .. " " .. default, true, false, true)
	vim.schedule(function()
		vim.api.nvim_feedkeys(keys, "n", false)
	end)
end

return M
