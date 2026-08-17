local M = {}

local keymaps = require("atlas.core.keymaps")

---@class AtlasLiveCommandOptions
---@field cwd string|nil
---@field env table<string, string|number>|nil

---@class AtlasLiveOutput
local Output = {}
Output.__index = Output

---@param value integer|nil
---@return boolean
local function valid_buf(value)
	return value ~= nil and vim.api.nvim_buf_is_valid(value)
end

---@param value integer|nil
---@return boolean
local function valid_win(value)
	return value ~= nil and vim.api.nvim_win_is_valid(value)
end

---@param callback fun()
local function on_main(callback)
	if vim.in_fast_event() then
		vim.schedule(callback)
	else
		callback()
	end
end

---@param title string
---@param close_keys string[]
---@return table
local function window_config(title, close_keys)
	local width = math.floor(vim.o.columns * 0.4)
	local height = math.floor(vim.o.lines * 0.25)

	return {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		footer = close_keys[1] and " " .. table.concat(close_keys, " / ") .. " close " or nil,
		footer_pos = close_keys[1] and "center" or nil,
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	}
end

---@param self AtlasLiveOutput
local function cleanup(self)
	self.buf = nil
	self.win = nil
	self.channel = nil
	self.closed = true
end

---@param self AtlasLiveOutput
---@return boolean
local function ensure_open(self)
	if self.closed then
		return false
	end
	if valid_win(self.win) and valid_buf(self.buf) then
		return true
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	local close_keys = keymaps.resolve("ui.close") or {}

	self.buf = buf
	self.win = vim.api.nvim_open_win(buf, true, window_config(self.title, close_keys))
	self.channel = vim.api.nvim_open_term(buf, {})

	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			self:cancel()
		end, { buffer = buf, silent = true, desc = "cancel output" })
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			cleanup(self)
		end,
	})

	return true
end

---@param self AtlasLiveOutput
---@param text string
local function send(self, text)
	on_main(function()
		if ensure_open(self) and self.channel then
			vim.api.nvim_chan_send(self.channel, text)
		end
	end)
end

---@param message string|string[]
function Output:write(message)
	local text = type(message) == "table" and table.concat(message, "\n") or tostring(message)
	if text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	send(self, text)
end

---@param cmd string[]
---@param on_exit fun(code: integer)|nil
---@param opts AtlasLiveCommandOptions|nil
function Output:run(cmd, on_exit, opts)
	opts = opts or {}

	---@param code integer
	local function finish(code)
		if on_exit then
			vim.schedule(function()
				on_exit(code)
			end)
		end
	end

	local function on_data(_, data)
		local text = table.concat(data, "\n")
		if text ~= "" then
			send(self, text)
		end
	end

	local function start()
		if not ensure_open(self) then
			finish(-1)
			return
		end

		local job_id
		job_id = vim.fn.jobstart(cmd, {
			cwd = opts.cwd,
			env = vim.tbl_extend("keep", opts.env or {}, { TERM = "xterm-256color" }),
			pty = true,
			width = vim.api.nvim_win_get_width(self.win),
			height = vim.api.nvim_win_get_height(self.win),
			on_stdout = on_data,
			on_exit = function(_, code)
				self.jobs[job_id] = nil
				finish(code)
			end,
		})
		if job_id > 0 then
			self.jobs[job_id] = true
		else
			self:write("Unable to start command")
			finish(-1)
		end
	end

	on_main(start)
end

function Output:close()
	on_main(function()
		if valid_win(self.win) then
			vim.api.nvim_win_close(self.win, true)
		elseif valid_buf(self.buf) then
			vim.api.nvim_buf_delete(self.buf, { force = true })
		else
			cleanup(self)
		end
	end)
end

function Output:cancel()
	on_main(function()
		for job_id in pairs(self.jobs) do
			vim.fn.jobstop(job_id)
		end
		self:close()
	end)
end

---@param title string
---@return AtlasLiveOutput
function M.create(title)
	return setmetatable({
		title = tostring(title or "Output"),
		buf = nil,
		win = nil,
		channel = nil,
		jobs = {},
		closed = false,
	}, Output)
end

return M
