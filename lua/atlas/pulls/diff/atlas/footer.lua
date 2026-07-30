local M = {}

local component = require("atlas.ui.components.footer")
local icons = require("atlas.ui.shared.icons")
local diff = require("atlas.ui.components.diff_hunks")
local spinner = require("atlas.ui.components.spinner")
local text_utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")
local window = require("atlas.ui.shared.window")

local namespace = vim.api.nvim_create_namespace("atlas_native_diff_footer")

---@class AtlasNativeDiffFooterNotice
---@field text string
---@field hl_group string
---@field token integer

---@class AtlasNativeDiffFooter
---@field buf integer
---@field win integer|nil
---@field notice AtlasNativeDiffFooterNotice
---@field spinner SpinnerInstance|nil

---@param buf integer
---@param win integer
---@return AtlasNativeDiffFooter
function M.new(buf, win)
	return {
		buf = buf,
		win = win,
		notice = { text = "", hl_group = "AtlasTextMuted", token = 0 },
		spinner = nil,
	}
end

---@param footer AtlasNativeDiffFooter
local function stop_spinner(footer)
	if footer.spinner then
		footer.spinner:stop()
		footer.spinner = nil
	end
end

---@param session AtlasNativeDiffSession
---@return integer additions, integer deletions
local function total_stats(session)
	local additions, deletions = 0, 0
	for _, file in ipairs(session.files) do
		local file_additions, file_deletions = diff.file_stats(file)
		additions = additions + file_additions
		deletions = deletions + file_deletions
	end
	return additions, deletions
end

---@param session AtlasNativeDiffSession
---@return string
local function identity(session)
	return string.format(
		"%s...%s",
		tostring(session.range.base_revision):sub(1, 8),
		tostring(session.range.head_revision):sub(1, 8)
	)
end

---@param text string
---@return integer
local function segment_width(text)
	text = vim.trim(text)
	return text == "" and 0 or vim.fn.strdisplaywidth(text) + 2
end

---@param session AtlasNativeDiffSession
---@param width integer
---@return table[]
local function segments(session, width)
	local additions, deletions = total_stats(session)
	local add_text = string.format("+%d", additions)
	local delete_text = string.format("-%d", deletions)
	local result = { { text = identity(session), hl_group = "AtlasFooterText" } }
	local optional = {
		{ text = session.footer.notice.text, hl_group = session.footer.notice.hl_group },
	}
	local remaining = math.max(0, width - segment_width(add_text) - segment_width(delete_text) - 1)
	for _, item in ipairs(optional) do
		local item_width = segment_width(item.text)
		if item_width > remaining and item == optional[1] and remaining >= 3 then
			item.text = text_utils.truncate(item.text, remaining - 2)
			item_width = segment_width(item.text)
		end
		if item_width > 0 and item_width <= remaining then
			item.align = "right"
			table.insert(result, item)
			remaining = remaining - item_width
		end
	end
	table.insert(result, {
		text = add_text,
		hl_group = "AtlasTextPositive",
		align = "right",
	})
	table.insert(result, {
		text = delete_text,
		hl_group = "AtlasLogError",
		align = "right",
	})
	return result
end

---@param session AtlasNativeDiffSession
function M.configure(session)
	local footer = session.footer
	if not footer.win or not vim.api.nvim_win_is_valid(footer.win) then
		return
	end
	window.apply_footer_opts(footer.win)
	local scope = { win = footer.win, scope = "local" }
	vim.api.nvim_set_option_value("winbar", "", scope)
	vim.api.nvim_set_option_value("diff", false, scope)
	vim.api.nvim_set_option_value("scrollbind", false, scope)
	vim.api.nvim_set_option_value("cursorbind", false, scope)
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:AtlasFooterBackground,NormalNC:AtlasFooterBackground,EndOfBuffer:AtlasFooterBackground",
		scope
	)
end

---@param session AtlasNativeDiffSession
function M.render(session)
	local footer = session.footer
	if session.closing or not footer.win or not vim.api.nvim_win_is_valid(footer.win) then
		return
	end
	if not vim.api.nvim_buf_is_valid(footer.buf) then
		return
	end

	local width = vim.api.nvim_win_get_width(footer.win)
	local block = component.render({ width = width, segments = segments(session, width) })
	vim.api.nvim_set_option_value("modifiable", true, { buf = footer.buf })
	vim.api.nvim_buf_set_lines(footer.buf, 0, -1, false, block.lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = footer.buf })
	vim.api.nvim_buf_clear_namespace(footer.buf, namespace, 0, -1)
	for _, span in ipairs(block.highlights) do
		local clamped = ui_utils.clamp_span(block.lines, span)
		if clamped then
			vim.api.nvim_buf_set_extmark(footer.buf, namespace, clamped.line, clamped.start_col, {
				end_row = clamped.line,
				end_col = clamped.end_col,
				hl_group = clamped.hl_group,
			})
		end
	end
end

---@param session AtlasNativeDiffSession
function M.reflow(session)
	local footer = session.footer
	if not footer.win or not vim.api.nvim_win_is_valid(footer.win) then
		return
	end
	pcall(function()
		vim.api.nvim_win_call(footer.win, function()
			vim.cmd("wincmd J")
		end)
	end)
	pcall(vim.api.nvim_win_set_height, footer.win, 1)
	M.render(session)
end

---@param session AtlasNativeDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration? integer
function M.notify(session, level, message, duration)
	local footer = session.footer
	message = tostring(message or ""):gsub("[\r\n]+", " | ")
	footer.notice.token = footer.notice.token + 1
	local token = footer.notice.token
	stop_spinner(footer)

	if level == "loading" then
		footer.notice.hl_group = "AtlasLogInfo"
		footer.spinner = spinner.create({
			on_tick = function(frame)
				if session.closing or footer.notice.token ~= token then
					stop_spinner(footer)
					return
				end
				footer.notice.text = string.format("%s %s", frame, message)
				M.render(session)
			end,
		})
		footer.notice.text = footer.spinner:text(message)
		footer.spinner:start()
		M.render(session)
		return
	end

	local icon_name = level == "warn" and "warning" or level
	local icon, hl_group = icons.general(icon_name)
	footer.notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	footer.notice.hl_group = hl_group
	M.render(session)

	vim.defer_fn(function()
		if session.closing or footer.notice.token ~= token then
			return
		end
		footer.notice.text = ""
		footer.notice.hl_group = "AtlasTextMuted"
		M.render(session)
	end, duration or 2500)
end

---@param session AtlasNativeDiffSession
function M.dispose(session)
	local footer = session.footer
	footer.notice.token = footer.notice.token + 1
	stop_spinner(footer)
end

return M
