local M = {}

local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local BACKGROUND_HL = "AtlasFooterBackground"
local Statusline = {}
Statusline.__index = Statusline

---@type table<integer, AtlasStatusline>
local instances = {}
local next_id = 0

---@class AtlasStatuslineSegment
---@field text string
---@field hl_group string|nil
---@field align "right"|nil
---@field priority integer|nil Higher values keep their space longer
---@field min_width integer|nil Truncate to this text width before hiding

---@class AtlasStatuslineNotice
---@field text string
---@field hl_group string

---@class AtlasStatuslineNoticeState: AtlasStatuslineNotice
---@field token integer

---@class AtlasStatuslineOptions
---@field help_key string|fun(): string|nil
---@field show_version boolean|nil
---@field left_padding integer|nil

---@class AtlasStatusline
---@field id integer
---@field expression string
---@field items AtlasStatuslineSegment[]
---@field notice AtlasStatuslineNoticeState
---@field loading_spinner SpinnerInstance|nil
---@field options AtlasStatuslineOptions
---@field disposed boolean

local function redraw()
	vim.cmd("redrawstatus")
end

---@param text any
---@return string
local function normalize(text)
	return tostring(text or ""):gsub("[\r\n]+", " | "):match("^%s*(.-)%s*$") or ""
end

---@param segment AtlasStatuslineSegment
---@return AtlasStatuslineSegment
local function copy_segment(segment)
	return {
		text = normalize(segment.text),
		hl_group = segment.hl_group,
		align = segment.align,
		priority = segment.priority,
		min_width = segment.min_width,
	}
end

---@param segment AtlasStatuslineSegment
---@return integer
local function segment_width(segment)
	return segment.text == "" and 0 or vim.api.nvim_strwidth(segment.text) + 1
end

---@param segments AtlasStatuslineSegment[]
---@param available integer
local function fit(segments, available)
	local total = 0
	local optional = {}

	for index, segment in ipairs(segments) do
		total = total + segment_width(segment)
		if segment.priority ~= nil then
			optional[#optional + 1] = { segment = segment, index = index }
		end
	end

	if total <= available then
		return
	end

	table.sort(optional, function(a, b)
		if a.segment.priority == b.segment.priority then
			return a.index < b.index
		end
		return a.segment.priority < b.segment.priority
	end)

	for _, item in ipairs(optional) do
		if total <= available then
			break
		end

		local segment = item.segment
		local before = segment_width(segment)
		if segment.min_width then
			local text_width = vim.api.nvim_strwidth(segment.text)
			local overflow = total - available
			segment.text = utils.truncate(segment.text, math.max(segment.min_width, text_width - overflow))
		else
			segment.text = ""
		end
		total = total - before + segment_width(segment)
	end

	for _, item in ipairs(optional) do
		if total <= available then
			break
		end
		local segment = item.segment
		if segment.text ~= "" and segment.min_width then
			total = total - segment_width(segment)
			segment.text = ""
		end
	end
end

---@return integer
local function current_width()
	local win = tonumber(vim.g.statusline_winid)
	if vim.o.laststatus == 3 or not win then
		return vim.o.columns
	end
	return vim.api.nvim_win_get_width(win)
end

---@param segment AtlasStatuslineSegment
---@return string
local function render_segment(segment)
	if segment.text == "" then
		return ""
	end

	local text = segment.text:gsub("%%", "%%%%")
	return string.format("%%#%s# %s%%#%s#", segment.hl_group or "AtlasFooterText", text, BACKGROUND_HL)
end

---@param output string[]
---@param segment AtlasStatuslineSegment
local function add(output, segment)
	local rendered = render_segment(segment)
	if rendered ~= "" then
		output[#output + 1] = rendered
	end
end

---@param segments AtlasStatuslineSegment[]
---@param current_notice AtlasStatuslineNotice|nil
---@param available integer|nil
---@param options { help_key: string|nil, show_version: boolean|nil, left_padding: integer|nil }|nil
---@return string
function M.format(segments, current_notice, available, options)
	options = options or {}
	local fitted = {}
	for _, segment in ipairs(segments or {}) do
		fitted[#fitted + 1] = copy_segment(segment)
	end
	if current_notice then
		fitted[#fitted + 1] = {
			text = normalize(current_notice.text),
			hl_group = current_notice.hl_group,
			align = "right",
		}
	end
	if options.show_version then
		fitted[#fitted + 1] = {
			text = string.format("atlas (%s)", utils.get_version()),
			hl_group = "AtlasFooterText",
			align = "right",
			priority = 0,
		}
	end
	if options.help_key then
		fitted[#fitted + 1] = {
			text = string.format("%s help", options.help_key),
			hl_group = "AtlasFooterWarning",
			align = "right",
			priority = 10,
		}
	end
	local left_padding = options.left_padding or 0
	fit(fitted, math.max((available or current_width()) - left_padding - 1, 0))

	local left, right = {}, {}
	for _, segment in ipairs(fitted) do
		add(segment.align == "right" and right or left, segment)
	end

	return table.concat({
		"%#" .. BACKGROUND_HL .. "#" .. string.rep(" ", left_padding),
		table.concat(left),
		"%=",
		table.concat(right),
		" ",
	})
end

function Statusline:stop_loading()
	if self.loading_spinner then
		self.loading_spinner:stop()
		self.loading_spinner = nil
	end
end

---@param token integer
---@param message string
function Statusline:start_loading(token, message)
	self.loading_spinner = spinner.create({
		interval_ms = 120,
		on_tick = function(frame)
			if self.disposed or self.notice.token ~= token then
				return
			end

			self.notice.text = string.format("%s %s", frame, message)
			redraw()
		end,
	})
	self.loading_spinner:start()
end

---@param text any
---@return string
local function sanitize_notice(text)
	local message = tostring(text or ""):gsub("[\r\n]+", " | ")
	return #message > 60 and message:sub(1, 57) .. "..." or message
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
	return icons.general(icon_name), highlights[level] or "AtlasFooterText"
end

---@param options AtlasStatuslineOptions|nil
---@return AtlasStatusline
function M.new(options)
	next_id = next_id + 1
	local instance = setmetatable({
		id = next_id,
		expression = string.format("%%!v:lua.require'atlas.ui.statusline'.current(%d)", next_id),
		items = {},
		notice = { text = "", hl_group = "AtlasFooterText", token = 0 },
		loading_spinner = nil,
		options = options or {},
		disposed = false,
	}, Statusline)
	return instance
end

---@param win integer|nil
function Statusline:attach(win)
	if self.disposed or not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	instances[self.id] = self
	vim.api.nvim_set_option_value("statusline", self.expression, { win = win, scope = "local" })
end

---@param win integer|nil
---@return boolean
function Statusline:is_attached(win)
	win = win or vim.api.nvim_get_current_win()
	return not self.disposed
		and vim.api.nvim_win_is_valid(win)
		and vim.api.nvim_get_option_value("statusline", { win = win }) == self.expression
end

function Statusline:clear_items()
	self.items = {}
	redraw()
end

---@param items AtlasStatuslineSegment[]
function Statusline:set_items(items)
	if not self.disposed then
		self.items = items or {}
		redraw()
	end
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@param text string
---@param duration_ms number|nil
function Statusline:notify(level, text, duration_ms)
	if self.disposed then
		return
	end

	local message = sanitize_notice(text)
	self.notice.token = self.notice.token + 1
	local token = self.notice.token
	self:stop_loading()

	local icon, hl_group = notice_style(level)
	self.notice.hl_group = hl_group
	if level == "loading" then
		self:start_loading(token, message)
		self.notice.text = self.loading_spinner and self.loading_spinner:text(message) or message
		redraw()
		return
	end

	self.notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	redraw()
	vim.defer_fn(function()
		if self.disposed or self.notice.token ~= token then
			return
		end
		self.notice.text = ""
		self.notice.hl_group = "AtlasFooterText"
		redraw()
	end, duration_ms or 2500)
end

function Statusline:clear_notice()
	self.notice.token = self.notice.token + 1
	self:stop_loading()
	self.notice.text = ""
	self.notice.hl_group = "AtlasFooterText"
	redraw()
end

function Statusline:reset()
	self.items = {}
	self:clear_notice()
end

---@return string
function Statusline:render()
	if self.disposed then
		return ""
	end
	local help_key = self.options.help_key
	if type(help_key) == "function" then
		help_key = help_key()
	end
	return M.format(self.items, self.notice, nil, {
		help_key = help_key,
		show_version = self.options.show_version,
		left_padding = self.options.left_padding,
	})
end

function Statusline:dispose()
	if self.disposed then
		return
	end
	self.notice.token = self.notice.token + 1
	self:stop_loading()
	self.disposed = true
	instances[self.id] = nil
	redraw()
end

M.default = M.new({
	help_key = function()
		local keys = keymaps.resolve("ui.help")
		return keys and keys[1]
	end,
	show_version = true,
})

---@param id integer|nil
---@return string
function M.current(id)
	local instance = id == nil and M.default or instances[id]
	return instance and instance:render() or ""
end

---@param win integer|nil
function M.attach(win)
	M.default:attach(win)
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
	if
		vim.o.laststatus ~= 3
		or not vim.api.nvim_win_is_valid(source_win)
		or not vim.api.nvim_win_is_valid(target_win)
	then
		return
	end
	local expression = vim.wo[source_win].statusline
	for _, instance in pairs(instances) do
		if expression == instance.expression then
			vim.api.nvim_set_option_value("statusline", expression, { win = target_win, scope = "local" })
			return
		end
	end
end

function M.clear_items()
	M.default:clear_items()
end

---@param items AtlasStatuslineSegment[]
function M.set_items(items)
	M.default:set_items(items)
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

function M.reset()
	M.default:reset()
end

return M
