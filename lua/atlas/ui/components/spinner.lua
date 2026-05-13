local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local DEFAULT_INTERVAL_NS = 100000000
local DEFAULT_INTERVAL_MS = 120

---@param interval_ns integer|nil
---@return string
function M.frame(interval_ns)
	local interval = interval_ns or DEFAULT_INTERVAL_NS
	if interval <= 0 then
		interval = DEFAULT_INTERVAL_NS
	end
	local idx = (math.floor(vim.loop.hrtime() / interval) % #FRAMES) + 1
	return FRAMES[idx]
end

---@param text string|nil
---@param interval_ns integer|nil
---@return string
function M.with_text(text, interval_ns)
	local label = text or "Loading..."
	return string.format("%s %s", M.frame(interval_ns), label)
end

---@class SpinnerInstance
---@field frame_index integer
---@field interval_ms integer
---@field timer uv_timer_t|nil
---@field on_tick fun(frame: string)|nil
---@field current_frame fun(self: SpinnerInstance): string
---@field text fun(self: SpinnerInstance, text?: string): string
---@field start fun(self: SpinnerInstance)
---@field stop fun(self: SpinnerInstance)
---@field is_running fun(self: SpinnerInstance): boolean

---@param opts? { interval_ms?: integer, on_tick?: fun(frame: string) }
---@return SpinnerInstance
function M.create(opts)
	opts = opts or {}
	local instance = {
		frame_index = 1,
		interval_ms = opts.interval_ms or DEFAULT_INTERVAL_MS,
		timer = nil,
		on_tick = opts.on_tick,
	}

	---@return string
	function instance:current_frame()
		return FRAMES[self.frame_index]
	end

	---@param text string|nil
	---@return string
	function instance:text(text)
		return string.format("%s %s", self:current_frame(), text or "Loading...")
	end

	function instance:start()
		if self.timer ~= nil then
			return
		end

		self.timer = vim.loop.new_timer()
		if self.timer == nil then
			return
		end

		self.timer:start(
			0,
			self.interval_ms,
			vim.schedule_wrap(function()
				self.frame_index = (self.frame_index % #FRAMES) + 1
				if type(self.on_tick) == "function" then
					self.on_tick(self:current_frame())
				end
			end)
		)
	end

	function instance:stop()
		if self.timer ~= nil then
			self.timer:stop()
			self.timer:close()
			self.timer = nil
		end
	end

	---@return boolean
	function instance:is_running()
		return self.timer ~= nil
	end

	return instance
end

return M
