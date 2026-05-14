local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local resolver = require("atlas.core.keymaps")
local ns = vim.api.nvim_create_namespace("atlas.footer")

---@class AtlasFooterNotice
---@field text string
---@field hl_group string
---@field token integer

---@type AtlasFooterNotice
local notice = {
	text = "",
	hl_group = "AtlasTextMuted",
	token = 0,
}

---@class AtlasFooterLoadingState
---@field spinner SpinnerInstance|nil
---@field text string

---@type AtlasFooterLoadingState
local loading = {
	spinner = nil,
	text = "",
}

local items = {}

---@param action_id AtlasKeymapActionId|string
---@param fallback string
---@return string
local function key_label(action_id, fallback)
	local keys = resolver.resolve(action_id)
	if type(keys) == "table" and #keys > 0 then
		return tostring(keys[1])
	end
	return fallback
end

local function stop_loading()
	if loading.spinner ~= nil then
		loading.spinner:stop()
		loading.spinner = nil
	end
end

local function start_loading(token)
	if loading.spinner ~= nil then
		return
	end

	loading.spinner = spinner.create({
		interval_ms = 120,
		on_tick = function(frame)
			if notice.token ~= token then
				stop_loading()
				return
			end

			notice.text = string.format("%s %s", frame, loading.text)
			M.refresh()
		end,
	})

	loading.spinner:start()
end

local function sanitize_notice_text(text)
	local msg = tostring(text or ""):gsub("[\r\n]+", " | ")
	if #msg > 60 then
		msg = msg:sub(1, 57) .. "..."
	end
	return msg
end

local function notice_icon(level)
	if level == "success" then
		return icons.general("success")
	end
	if level == "warn" then
		return icons.general("warning")
	end
	if level == "error" then
		return icons.general("error")
	end
	if level == "info" then
		return icons.general("info")
	end
	if level == "loading" then
		return "" -- spinner will be used instead of a static icon for loading state
	end

	return ""
end

local function notice_hl(level)
	if level == "success" then
		return "AtlasTextPositive"
	end
	if level == "warn" then
		return "AtlasLogWarn"
	end
	if level == "error" then
		return "AtlasLogError"
	end
	if level == "info" then
		return "AtlasLogInfo"
	end
	return "AtlasTextMuted"
end

local ui_utils = require("atlas.ui.utils")

---@param list table[]|nil
---@return table[]
local function clone_segments(list)
	local out = {}
	for _, seg in ipairs(list or {}) do
		table.insert(out, vim.deepcopy(seg))
	end
	return out
end

---@param segments table[]|nil
---@param line_index integer
---@return string
---@return table[]
local function build_segments_line(segments, line_index)
	local line = ""
	local highlights = {}
	local col = 0

	for _, seg in ipairs(segments or {}) do
		local normalized = vim.trim(tostring(seg.text or ""))
		local text = normalized == "" and "" or (" " .. normalized .. " ")
		line = line .. text

		if seg.hl_group ~= nil and text ~= "" then
			table.insert(highlights, {
				line = line_index,
				start_col = col,
				end_col = col + #text,
				hl_group = seg.hl_group,
			})
		end

		col = col + #text
	end

	return line, highlights
end

---@param left_items table[]|nil
---@param current_notice AtlasFooterNotice|nil
---@return table[]
local function segments_for(left_items, current_notice)
	local snapshot_notice = current_notice or notice
	local left = clone_segments(left_items or items)

	local right = {
		{
			text = snapshot_notice.text ~= "" and snapshot_notice.text or "",
			hl_group = snapshot_notice.text ~= "" and snapshot_notice.hl_group or "AtlasTextMuted",
			align = "right",
		},
		{ text = string.format("atlas (%s)", utils.get_version()), hl_group = "AtlasTextMuted", align = "right" },
		{
			text = string.format("%s help", key_label("ui.help", "g?")),
			hl_group = "AtlasTextWarning",
			align = "right",
		},
	}

	for _, seg in ipairs(right) do
		table.insert(left, seg)
	end

	return left
end

function M.clear_items()
	items = {}
	M.refresh()
end

---@param seg table
function M.register_item(seg)
	table.insert(items, vim.deepcopy(seg))
	M.refresh()
end

---@param new_items table[]
function M.set_items(new_items)
	items = clone_segments(new_items or {})
	M.refresh()
end

---@param level "success"|"warn"|"error"|"info"|"loading"
---@param text string
---@param duration_ms number|nil
function M.notify(level, text, duration_ms)
	local message = sanitize_notice_text(text)
	notice.token = notice.token + 1
	local token = notice.token

	stop_loading()

	if level == "loading" then
		notice.hl_group = notice_hl("info")
		loading.text = message

		start_loading(token)
		notice.text = loading.spinner ~= nil and loading.spinner:text(loading.text) or loading.text
		M.refresh()
		return
	end

	local icon = notice_icon(level)
	notice.text = icon ~= "" and string.format("%s %s", icon, message) or message
	notice.hl_group = notice_hl(level)

	M.refresh()

	vim.defer_fn(function()
		if notice.token ~= token then
			return
		end
		notice.text = ""
		notice.hl_group = "AtlasTextMuted"
		M.refresh()
	end, duration_ms or 2500)
end

-- opts:
--   width: number
--   footer_hl: string (optional, default AtlasFooterBackground)
--   segments: {
--     { text = "PRs", hl_group = "AtlasFooterText" },
--     { text = " | ", hl_group = "AtlasFooterText" },
--     { text = "@emrearmagan", hl_group = "AtlasFooterText" },
--   }
--
---@ opts { width?: number, footer_hl?: string, segments?: table[] }
---@return { lines: string[], highlights: table[] }
function M.render(opts)
	local width = opts.width or vim.o.columns
	local footer_hl = opts.footer_hl or "AtlasFooterBackground"
	local left_segments, right_segments = {}, {}
	for _, seg in ipairs(opts.segments or {}) do
		if seg.align == "right" then
			table.insert(right_segments, seg)
		else
			table.insert(left_segments, seg)
		end
	end

	local left_line, left_hls = build_segments_line(left_segments, 0)
	local right_line, right_hls = build_segments_line(right_segments, 0)

	local right_width = ui_utils.text_width(right_line)
	local max_left = math.max(0, width - right_width - 2)
	if ui_utils.text_width(left_line) > max_left then
		local trimmed = vim.fn.strcharpart(left_line, 0, math.max(0, max_left - 1)) .. ".."
		left_line = trimmed
	end

	local gap = width - ui_utils.text_width(left_line) - right_width
	if gap < 1 then
		gap = 1
	end

	local line = left_line .. string.rep(" ", gap) .. right_line
	if ui_utils.text_width(line) < width then
		line = line .. string.rep(" ", width - ui_utils.text_width(line))
	end

	local highlights = {}
	for _, hl in ipairs(left_hls) do
		table.insert(highlights, hl)
	end
	local right_offset = #left_line + gap
	for _, hl in ipairs(right_hls) do
		table.insert(highlights, {
			line = hl.line,
			start_col = hl.start_col + right_offset,
			end_col = hl.end_col + right_offset,
			hl_group = hl.hl_group,
		})
	end

	return {
		lines = { line },
		highlights = vim.list_extend({
			{
				line = 0,
				start_col = 0,
				end_col = math.max(width, 1),
				hl_group = footer_hl,
			},
		}, highlights),
	}
end

function M.refresh()
	local layout = require("atlas.ui.layout")
	local win = layout.win_id("footer")
	local buf = layout.buf_id("footer")

	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local refresh_token = notice.token
	local items_snapshot = clone_segments(items)
	local notice_snapshot = {
		text = notice.text,
		hl_group = notice.hl_group,
		token = notice.token,
	}

	local width = vim.api.nvim_win_get_width(win)
	local block = M.render({
		width = width,
		segments = segments_for(items_snapshot, notice_snapshot),
	})

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, block.lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	if refresh_token ~= notice.token then
		return
	end

	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(block.highlights or {}) do
		if refresh_token ~= notice.token then
			return
		end
		local clamped = ui_utils.clamp_span(block.lines, span)
		if clamped ~= nil then
			vim.api.nvim_buf_set_extmark(buf, ns, clamped.line, clamped.start_col, {
				end_row = clamped.line,
				end_col = clamped.end_col,
				hl_group = clamped.hl_group,
			})
		end
	end
end

function M.setup() end

return M
