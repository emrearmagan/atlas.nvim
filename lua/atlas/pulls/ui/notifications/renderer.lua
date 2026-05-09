local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

local PADDING_X = 2
local PADDING = string.rep(" ", PADDING_X)

---@param notifications AtlasNotification[]
---@param width integer
---@return string[] lines, table[] spans, table<integer, table> line_map
function M.render(notifications, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if #notifications == 0 then
		local empty = PADDING .. "No notifications."
		table.insert(lines, empty)
		table.insert(spans, {
			line = 0,
			start_col = 0,
			end_col = #empty,
			hl_group = "AtlasTextMuted",
		})
		return lines, spans, line_map
	end

	for i, n in ipairs(notifications) do
		local dot = n.unread and icons.general("dot") or " "
		local dot_hl = n.unread and "AtlasLogInfo" or "AtlasTextMuted"

		local type_icon = n.icon or ""
		local type_hl = n.icon_hl or "AtlasTextMuted"

		local prefix
		if type_icon ~= "" then
			prefix = PADDING .. dot .. " " .. type_icon .. "  "
		else
			prefix = PADDING .. dot .. " "
		end
		local prefix_w = vim.api.nvim_strwidth(prefix)
		local prefix_bytes = #prefix

		local raw_timestamp = tostring(n.timestamp or "")
		local timestamp = ""
		if raw_timestamp ~= "" then
			local formatted = utils.relative_time_text(raw_timestamp)
			if formatted ~= "" and formatted ~= "-" then
				timestamp = formatted
			end
		end
		local timestamp_w = timestamp ~= "" and vim.api.nvim_strwidth(timestamp) or 0
		local timestamp_pad = timestamp ~= "" and 2 or 0

		local title = tostring(n.title or "")
		local title_max = math.max(1, width - prefix_w - PADDING_X - timestamp_w - timestamp_pad)
		local title_display = utils.truncate(title, title_max)
		local title_w = vim.api.nvim_strwidth(title_display)

		local line1 = prefix .. title_display
		if timestamp ~= "" then
			local gap = math.max(timestamp_pad, width - prefix_w - title_w - timestamp_w - PADDING_X)
			line1 = line1 .. string.rep(" ", gap) .. timestamp
		end
		table.insert(lines, line1)
		local lnum1 = #lines - 1

		local dot_start = PADDING_X
		local dot_end = dot_start + #dot
		table.insert(spans, { line = lnum1, start_col = dot_start, end_col = dot_end, hl_group = dot_hl })

		if type_icon ~= "" then
			local icon_start = dot_end + 1
			local icon_end = icon_start + #type_icon
			table.insert(spans, { line = lnum1, start_col = icon_start, end_col = icon_end, hl_group = type_hl })
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

		line_map[#lines] = { kind = "notification", notification = n }

		local subtitle = tostring(n.subtitle or "")
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
			line_map[#lines] = { kind = "notification", notification = n }
		end

		if i < #notifications then
			local sep_w = math.max(8, width - (PADDING_X * 2))
			local sep = PADDING .. string.rep("─", sep_w)
			table.insert(lines, sep)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #sep, hl_group = "AtlasBorder" })
		end
	end

	return lines, spans, line_map
end

return M
