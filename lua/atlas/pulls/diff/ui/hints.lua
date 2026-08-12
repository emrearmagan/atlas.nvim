local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_diff_hints")
local comment_icon = icons.general("comment")
local note_icon, note_icon_hl = icons.general("pin")
local max_text_width = 48

---@class AtlasDiffHint
---@field buf integer
---@field line integer
---@field kind "comment"|"note"
---@field text string

---@param items AtlasDiffHint[]
---@return [string, string][]
function M.chunks(items)
	local chunks = {}
	for index, item in ipairs(items) do
		local text = utils.strip_markup(item.text):gsub("%s+", " ")
		text = utils.truncate(text, max_text_width)
		if index == 1 then
			chunks[#chunks + 1] = { "  ", "AtlasTextMuted" }
		else
			chunks[#chunks + 1] = { "   ", "AtlasTextMuted" }
		end
		if item.kind == "comment" then
			chunks[#chunks + 1] = { comment_icon .. " ", "AtlasLogInfo" }
		else
			chunks[#chunks + 1] = { note_icon .. " ", note_icon_hl }
		end
		chunks[#chunks + 1] = { text, "AtlasTextMuted" }
	end
	return chunks
end

---@param current AtlasDiffCurrent
function M.clear(current)
	for _, side in ipairs({ current.left, current.right }) do
		if vim.api.nvim_buf_is_valid(side.buf) then
			vim.api.nvim_buf_clear_namespace(side.buf, namespace, 0, -1)
		end
	end
end

---@param current AtlasDiffCurrent
---@param items AtlasDiffHint[]
function M.render(current, items)
	M.clear(current)
	local grouped = {}
	for _, item in ipairs(items) do
		grouped[item.buf] = grouped[item.buf] or {}
		grouped[item.buf][item.line] = grouped[item.buf][item.line] or {}
		grouped[item.buf][item.line][#grouped[item.buf][item.line] + 1] = item
	end
	for buf, by_line in pairs(grouped) do
		local line_count = vim.api.nvim_buf_line_count(buf)
		for line, line_items in pairs(by_line) do
			if line >= 1 and line <= line_count then
				vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
					virt_text = M.chunks(line_items),
					virt_text_pos = "eol",
					hl_mode = "combine",
					priority = 1100,
				})
			end
		end
	end
end

return M
