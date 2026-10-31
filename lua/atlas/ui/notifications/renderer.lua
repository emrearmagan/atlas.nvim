local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param text string
---@param hl_group string
---@return string[] lines, table[] spans, table<integer, AtlasNotification> line_map
function M.message(text, hl_group)
	local line = PADDING .. text
	return { line }, { { line = 0, start_col = 0, end_col = #line, hl_group = hl_group } }, {}
end

---@param notifications AtlasNotification[]
---@param width integer
---@return string[] lines, table[] spans, table<integer, AtlasNotification> line_map
function M.render(notifications, width)
	if #notifications == 0 then
		return M.message("No notifications.", "AtlasTextMuted")
	end

	local lines = {}
	local spans = {}
	local line_map = {}

	for i, n in ipairs(notifications) do
		local type_icon, type_hl = icons.get("info")
		if n.kind == "pr" then
			type_icon, type_hl = icons.get("pr")
		elseif n.kind == "issue" then
			type_icon, type_hl = icons.get("issue")
		elseif n.kind == "checks" then
			type_icon, type_hl = icons.get("tasks")
		elseif n.kind == "release" then
			type_icon, type_hl = icons.get("tag")
		elseif n.kind == "discussion" then
			type_icon, type_hl = icons.get("conversation")
		end

		local prefix = type_icon ~= "" and PADDING .. type_icon .. " " or PADDING
		local prefix_w = vim.api.nvim_strwidth(prefix)
		local prefix_bytes = #prefix

		local timestamp = n.timestamp and utils.relative_time_text(n.timestamp) or ""
		if timestamp == "-" then
			timestamp = ""
		end
		local timestamp_w = timestamp ~= "" and vim.api.nvim_strwidth(timestamp) or 0
		local timestamp_pad = timestamp ~= "" and 2 or 0

		local title_max = math.max(1, width - prefix_w - PADDING_X - timestamp_w - timestamp_pad)
		local title_display = utils.truncate(n.title, title_max)
		local title_w = vim.api.nvim_strwidth(title_display)

		local line1 = prefix .. title_display
		if timestamp ~= "" then
			local gap = math.max(timestamp_pad, width - prefix_w - title_w - timestamp_w - PADDING_X)
			line1 = line1 .. string.rep(" ", gap) .. timestamp
		end
		table.insert(lines, line1)
		local lnum1 = #lines - 1

		if type_icon ~= "" then
			table.insert(spans, {
				line = lnum1,
				start_col = PADDING_X,
				end_col = PADDING_X + #type_icon,
				hl_group = n.unread and type_hl or "AtlasTextMuted",
			})
		end

		if not n.unread then
			table.insert(spans, {
				line = lnum1,
				start_col = prefix_bytes,
				end_col = prefix_bytes + #title_display,
				hl_group = "AtlasTextMuted",
			})
		end

		if timestamp ~= "" then
			local ts_start = #line1 - #timestamp
			table.insert(spans, {
				line = lnum1,
				start_col = ts_start,
				end_col = ts_start + #timestamp,
				hl_group = "AtlasTextMuted",
			})
		end

		line_map[#lines] = n

		local subtitle = n.subtitle or ""
		if subtitle ~= "" then
			local indent = string.rep(" ", prefix_w)
			local subtitle_max = math.max(1, width - prefix_w - PADDING_X)
			local subtitle_display = utils.truncate(subtitle, subtitle_max)
			local line2 = indent .. subtitle_display

			table.insert(lines, line2)
			local lnum2 = #lines - 1
			table.insert(spans, {
				line = lnum2,
				start_col = prefix_w,
				end_col = prefix_w + #subtitle_display,
				hl_group = "AtlasTextMuted",
			})
			line_map[#lines] = n
		end

		if i < #notifications then
			local sep = string.rep("─", width)
			table.insert(lines, sep)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #sep, hl_group = "AtlasBorder" })
		end
	end

	return lines, spans, line_map
end

return M
