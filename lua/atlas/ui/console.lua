local M = {}

local keymaps = require("atlas.core.keymaps")

---@class AtlasConsoleOutput
---@field chunks string[]
---@field buf integer|nil
---@field win integer|nil
---@field channel integer|nil
---@field finished boolean
---@field dismissed boolean
local Output = {}
Output.__index = Output

---@type AtlasConsoleOutput|nil
local latest

---@param output AtlasConsoleOutput
local function hide(output)
	output.dismissed = true
	if output.win and vim.api.nvim_win_is_valid(output.win) then
		vim.api.nvim_win_close(output.win, true)
	end
	output.win = nil
end

---@param output AtlasConsoleOutput
---@param focus boolean
local function show(output, focus)
	if output ~= latest then
		return
	end
	if output.win and vim.api.nvim_win_is_valid(output.win) then
		if focus then
			vim.api.nvim_set_current_win(output.win)
		end
		return
	end

	if not output.buf then
		output.buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(output.buf, "atlas://console")
		vim.bo[output.buf].bufhidden = "hide"
		vim.bo[output.buf].filetype = "atlas-ui.console"

		for _, key in ipairs(keymaps.resolve("ui.close") or {}) do
			vim.keymap.set("n", key, function()
				hide(output)
			end, { buffer = output.buf, silent = true, nowait = true, desc = "Hide console" })
		end

		vim.api.nvim_create_autocmd("BufWinLeave", {
			buffer = output.buf,
			callback = function()
				output.win = nil
				output.dismissed = true
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = output.buf,
			callback = function()
				output.buf = nil
				output.channel = nil
			end,
		})
	end

	output.win = vim.api.nvim_open_win(output.buf, focus, {
		relative = "editor",
		anchor = "SW",
		width = vim.o.columns,
		height = math.max(1, math.floor(vim.o.lines * 0.3)),
		row = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0),
		col = 0,
		style = "minimal",
		border = { "", "─", "", "", "", "", "", "" },
		title = " Atlas Console ",
	})
	vim.wo[output.win].winbar = ""
	vim.wo[output.win].wrap = false

	if not output.channel then
		output.channel = vim.api.nvim_open_term(output.buf, {})
		vim.bo[output.buf].modifiable = false
		vim.api.nvim_chan_send(output.channel, table.concat(output.chunks))
	end
end

---@param chunk string
function Output:write(chunk)
	vim.schedule(function()
		if self ~= latest or self.finished then
			return
		end
		self.chunks[#self.chunks + 1] = chunk
		if self.channel then
			vim.api.nvim_chan_send(self.channel, chunk)
		end
	end)
end

---@param code integer|nil
function Output:finish(code)
	vim.schedule(function()
		if self ~= latest or self.finished then
			return
		end
		self.finished = true
		local result = code == nil and "Cancelled" or "Process exited with code: " .. code
		local chunk = "\r\n" .. result .. "\r\n"
		self.chunks[#self.chunks + 1] = chunk
		if self.channel then
			vim.api.nvim_chan_send(self.channel, chunk)
		end
	end)
end

---@param title string
---@param cwd string|nil
---@return AtlasConsoleOutput
function M.start(title, cwd)
	if latest then
		local previous = latest
		vim.schedule(function()
			hide(previous)
			if previous.buf then
				vim.api.nvim_buf_delete(previous.buf, { force = true })
			end
			previous.chunks = {}
		end)
	end

	---@type AtlasConsoleOutput
	local output = setmetatable({
		chunks = { "> " .. title .. "\r\n", cwd and cwd .. "\r\n\r\n" or "" },
		finished = false,
		dismissed = false,
	}, Output)
	latest = output
	return output
end

---@param focus boolean|nil
---@param delay_ms integer|nil
function M.open(focus, delay_ms)
	local output = latest
	local function open()
		if output then
			if delay_ms and (output.finished or output.dismissed) then
				return
			end
			show(output, focus ~= false)
		else
			require("atlas.core.notify").info("No command output", { vim_notify = true })
		end
	end
	if delay_ms then
		vim.defer_fn(open, delay_ms)
	else
		vim.schedule(open)
	end
end

return M
