local config = require("atlas.config")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local M = {}

local BACKGROUND_HL = "AtlasFooterBackground"

---@type table<integer, AtlasStatusline>
local instances = {}
---@type table<integer, AtlasStatusline>
local windows = {}
local lualine_paused = false
local next_id = 0

---@alias AtlasStatuslineSegment { text: string, hl_group?: string }

---@class AtlasStatuslineContext
---@field win integer Window of the statusline
---@field buf integer Buffer in that window
---@field user? AtlasUser
---@field pr? PullRequest
---@field issue? Issue
---@field list? { items: PullRequest[]|Issue[], page?: { current: integer, total?: integer } } nil while loading
---@field diff? AtlasDiffSession
---@field pipeline? PullsPipelinesSelection

---@alias AtlasStatuslineComponent fun(ctx: AtlasStatuslineContext): string|AtlasStatuslineSegment|AtlasStatuslineSegment[]|nil

-- Components in order. Everything after "%=" goes right, two "%=" center the part between them.
---@alias AtlasStatuslineLayout (AtlasStatuslineComponent|"%=")[]

---@class AtlasStatuslineOptions
---@field layout AtlasStatuslineLayout Default layout
---@field context? fun(ctx: AtlasStatuslineContext)

---@class AtlasStatusline
---@field id integer
---@field expression string
---@field notice { text: string, hl_group: string, token: integer }
---@field loading_spinner SpinnerInstance|nil
---@field spinner_tick boolean|nil
---@field parts { win: integer, sections: string[] }|nil
---@field options AtlasStatuslineOptions
---@field disposed boolean
local Statusline = {}
Statusline.__index = Statusline

function Statusline:redraw()
	for _, instance in pairs(windows) do
		if instance == self then
			vim.cmd("redrawstatus")
			return
		end
	end
end

---@param text any
---@return string
local function normalize(text)
	return tostring(text or ""):gsub("[\r\n]+", " | "):match("^%s*(.-)%s*$") or ""
end

---@param statusline AtlasStatusline
local function stop_loading(statusline)
	if statusline.loading_spinner then
		statusline.loading_spinner:stop()
		statusline.loading_spinner = nil
	end
end

---@param statusline AtlasStatusline
---@param token integer
---@param message string
local function start_loading(statusline, token, message)
	statusline.loading_spinner = spinner.create({
		interval_ms = 120,
		on_tick = function(frame)
			if statusline.disposed or statusline.notice.token ~= token then
				return
			end

			statusline.notice.text = string.format("%s %s", frame, message)

			statusline.spinner_tick = true
			statusline:redraw()
			statusline.spinner_tick = false
		end,
	})
	statusline.loading_spinner:start()
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@return string icon
---@return string hl_group
local function notice_style(level)
	if level == "loading" then
		return "", "AtlasFooterInfo"
	end

	local icon_name = level == "warn" and "warning" or level
	local highlights = {
		success = "AtlasFooterSuccess",
		warn = "AtlasFooterWarning",
		error = "AtlasFooterError",
		info = "AtlasFooterInfo",
	}
	return icons.get(icon_name), highlights[level] or "AtlasFooterText"
end

---@param win integer|nil
---@return boolean
function M.enabled(win)
	win = win or vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	return config.statusline_enabled(vim.api.nvim_win_get_buf(win), win)
end

---@param options AtlasStatuslineOptions
---@return AtlasStatusline
function M.new(options)
	next_id = next_id + 1
	local instance = setmetatable({
		id = next_id,
		expression = string.format("%%!v:lua.require'atlas.ui.statusline'.current(%d)", next_id),
		notice = { text = "", hl_group = "AtlasFooterText", token = 0 },
		loading_spinner = nil,
		options = options,
		disposed = false,
	}, Statusline)
	return instance
end

---@return boolean
local function current_tab_attached()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if windows[win] then
			return true
		end
	end
	return false
end

-- Honestly, I've been fighting my ass off with lualine, which keeps overriding the statusline.
-- Sure, I could ignore every atlas filetype in the lualine config, but forget to set that and you lose
-- the included statusline, which holds most of the information.
-- So instead of making everyone configure that, lualine just takes a nap while an atlas tab is focused.
local function sync_lualine()
	local lualine = package.loaded["lualine"]
	local pause = current_tab_attached()
	if not lualine or pause == lualine_paused then
		return
	end

	lualine_paused = pause
	local laststatus = vim.o.laststatus
	lualine.hide({ place = { "statusline" }, unhide = not pause })
	if pause then
		vim.o.laststatus = laststatus
		for win, instance in pairs(windows) do
			instance:attach(win)
		end
	end
end

---@param win integer|nil
function Statusline:attach(win)
	if not M.enabled(win) or self.disposed or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	instances[self.id] = self
	windows[win] = self
	vim.api.nvim_set_option_value("statusline", self.expression, { win = win, scope = "local" })
	sync_lualine()
end

---@param win integer|nil
---@return boolean
function Statusline:is_attached(win)
	win = win or vim.api.nvim_get_current_win()
	return M.enabled(win)
		and not self.disposed
		and vim.api.nvim_win_is_valid(win)
		and vim.api.nvim_get_option_value("statusline", { win = win }) == self.expression
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@param text string
---@param duration_ms number|nil
function Statusline:notify(level, text, duration_ms)
	if self.disposed then
		return
	end

	local message = utils.truncate(normalize(text), 60)
	self.notice.token = self.notice.token + 1
	local token = self.notice.token
	stop_loading(self)

	local icon, hl_group = notice_style(level)
	self.notice.hl_group = hl_group
	if level == "loading" then
		start_loading(self, token, message)
		self.notice.text = self.loading_spinner:text(message)
		self:redraw()
		return
	end

	self.notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	self:redraw()
	vim.defer_fn(function()
		if self.disposed or self.notice.token ~= token then
			return
		end
		self.notice.text = ""
		self.notice.hl_group = "AtlasFooterText"
		self:redraw()
	end, duration_ms or 2500)
end

function Statusline:clear_notice()
	self.notice.token = self.notice.token + 1
	stop_loading(self)
	self.notice.text = ""
	self.notice.hl_group = "AtlasFooterText"
	self:redraw()
end

---@param text string
---@param hl_group string|nil
---@param space string
---@return string
local function format_part(text, hl_group, space)
	text = normalize(text):gsub("%%", "%%%%")
	if text == "" then
		return ""
	end
	return string.format("%%#%s#%s%s%%#%s#", hl_group or "AtlasFooterText", space, text, BACKGROUND_HL)
end

---@param statusline AtlasStatusline
---@param win integer
---@return { win: integer, sections: string[] }
local function render_components(statusline, win)
	local buf = vim.api.nvim_win_get_buf(win)
	---@type AtlasStatuslineContext
	local ctx = { win = win, buf = buf }
	if statusline.options.context then
		statusline.options.context(ctx)
	end

	local sections = { {} }
	local custom = config.options.ui.statusline.layout
	for _, component in ipairs(custom and custom(buf, win, ctx) or statusline.options.layout) do
		if component == "%=" then
			sections[#sections + 1] = {}
		else
			local result = component(ctx)
			if type(result) == "string" then
				result = { text = result }
			end
			if result and result.text then
				result = { result }
			end

			local section = sections[#sections]
			---@cast result AtlasStatuslineSegment[]|nil
			for index, segment in ipairs(result or {}) do
				local gap = index == 1 and (#sections > 1 or #section > 0)
				local part = format_part(segment.text, segment.hl_group, gap and "  " or " ")
				if part ~= "" then
					section[#section + 1] = part
				end
			end
		end
	end

	return { win = win, sections = vim.tbl_map(table.concat, sections) }
end

---@return string
function Statusline:render()
	if self.disposed then
		return ""
	end

	local win = tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
	if not (self.spinner_tick and self.parts and self.parts.win == win) then
		self.parts = render_components(self, win)
	end

	-- Messages come first in the last section and grow to the left, so the components after them keep their place.
	local sections = self.parts.sections
	local notice = format_part(self.notice.text, self.notice.hl_group, " ")
	local before = table.concat(sections, "%=", 1, math.max(#sections - 1, 1))
	local last = #sections > 1 and sections[#sections] or ""
	return "%#" .. BACKGROUND_HL .. "#" .. before .. "%=" .. notice .. last .. " "
end

function Statusline:dispose()
	if self.disposed then
		return
	end
	self.notice.token = self.notice.token + 1
	stop_loading(self)
	self.disposed = true
	self:redraw()
	instances[self.id] = nil
	for win, instance in pairs(windows) do
		if instance == self then
			windows[win] = nil
		end
	end
end

---@param id integer
---@return string
function M.current(id)
	local instance = instances[id]
	return instance and instance:render() or ""
end

---@param win integer|nil
function M.detach(win)
	if win then
		windows[win] = nil
		vim.schedule(sync_lualine)
	end
end

---@param win integer|nil
---@return boolean
function M.is_attached(win)
	for _, instance in pairs(instances) do
		if instance:is_attached(win) then
			return true
		end
	end
	return false
end

---@param target_win integer
---@param source_win integer
function M.inherit(target_win, source_win)
	local instance = windows[source_win]
	if instance then
		instance:attach(target_win)
	end
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@param text string
---@param duration_ms number|nil
function M.notify(level, text, duration_ms)
	for _, instance in pairs(instances) do
		if instance:is_attached() then
			instance:notify(level, text, duration_ms)
			return
		end
	end
end

function M.clear_notice()
	for _, instance in pairs(instances) do
		if instance:is_attached() then
			instance:clear_notice()
			return
		end
	end
end

local group = vim.api.nvim_create_augroup("AtlasStatusline", { clear = true })

vim.api.nvim_create_autocmd("OptionSet", {
	group = group,
	pattern = "statusline",
	callback = function()
		local win = vim.api.nvim_get_current_win()
		local instance = windows[win]
		if not instance or instance:is_attached(win) then
			return
		end

		-- Other statusline plugins can overwrite ours during a refresh.
		vim.schedule(function()
			if windows[win] == instance and not instance:is_attached(win) then
				instance:attach(win)
			end
		end)
	end,
})

vim.api.nvim_create_autocmd("TabEnter", {
	group = group,
	callback = sync_lualine,
})

vim.api.nvim_create_autocmd("WinClosed", {
	group = group,
	callback = function(event)
		M.detach(tonumber(event.match))
	end,
})

return M
