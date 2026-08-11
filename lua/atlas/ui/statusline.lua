local M = {}

local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")

local BACKGROUND_HL = "AtlasFooterBackground"
local EXPRESSION = "%!v:lua.require'atlas.ui.statusline'.current()"
local DIFF_EXPRESSION = "%!v:lua.require'atlas.pulls.diff.ui.statusline'.current()"

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

---@type AtlasStatuslineSegment[]
local items = {}

---@type AtlasStatuslineNoticeState
local notice = {
	text = "",
	hl_group = "AtlasFooterText",
	token = 0,
}

---@type SpinnerInstance|nil
local loading_spinner

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
	fit(fitted, available or current_width())

	local left, right = {}, {}
	for _, segment in ipairs(fitted) do
		add(segment.align == "right" and right or left, segment)
	end

	return table.concat({
		"%#" .. BACKGROUND_HL .. "#%<" .. string.rep(" ", options.left_padding or 0),
		table.concat(left),
		"%=",
		table.concat(right),
		" ",
	})
end

local function stop_loading()
	if loading_spinner then
		loading_spinner:stop()
		loading_spinner = nil
	end
end

---@param token integer
---@param message string
local function start_loading(token, message)
	loading_spinner = spinner.create({
		interval_ms = 120,
		on_tick = function(frame)
			if notice.token ~= token then
				return
			end

			notice.text = string.format("%s %s", frame, message)
			redraw()
		end,
	})
	loading_spinner:start()
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

---@param win integer
function M.attach(win)
	vim.api.nvim_set_option_value("statusline", EXPRESSION, { win = win, scope = "local" })
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
	local source_statusline = vim.wo[source_win].statusline
	if source_statusline == EXPRESSION or source_statusline == DIFF_EXPRESSION then
		vim.api.nvim_set_option_value("statusline", source_statusline, { win = target_win, scope = "local" })
	end
end

function M.clear_items()
	items = {}
	redraw()
end

---@param new_items AtlasStatuslineSegment[]
function M.set_items(new_items)
	items = new_items or {}
	redraw()
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@param text string
---@param duration_ms number|nil
function M.notify(level, text, duration_ms)
	local message = sanitize_notice(text)
	notice.token = notice.token + 1
	local token = notice.token
	stop_loading()

	local icon, hl_group = notice_style(level)
	notice.hl_group = hl_group
	if level == "loading" then
		start_loading(token, message)
		notice.text = loading_spinner and loading_spinner:text(message) or message
		redraw()
		return
	end

	notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	redraw()
	vim.defer_fn(function()
		if notice.token ~= token then
			return
		end
		notice.text = ""
		notice.hl_group = "AtlasFooterText"
		redraw()
	end, duration_ms or 2500)
end

---@return string
function M.current()
	local help_keys = keymaps.resolve("ui.help")
	return M.format(items, notice, nil, {
		help_key = help_keys and help_keys[1],
		show_version = true,
	})
end

function M.clear_notice()
	notice.token = notice.token + 1
	stop_loading()
	notice.text = ""
	notice.hl_group = "AtlasFooterText"
	redraw()
end

function M.reset()
	items = {}
	M.clear_notice()
end

return M
