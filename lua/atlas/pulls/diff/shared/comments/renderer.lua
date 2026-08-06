local M = {}

local box = require("atlas.ui.components.box")
local threads = require("atlas.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_review_comments")

---@class AtlasCommentRendererContext
---@field threads AtlasReviewThreadNode[]
---@field expanded_threads table<string, boolean>
---@field old_path string
---@field new_path string
---@field reaction_options PullsReactionOption[]|nil

---@param buf integer
---@return integer
local function buffer_width(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.api.nvim_win_is_valid(win) then
			return vim.api.nvim_win_get_width(win)
		end
	end
	return vim.o.columns
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param list AtlasReviewThreadNode[]
---@return [string, string][][]
function M.thread_lines(context, buf, list)
	local width = buffer_width(buf)
	local lines, spans = threads.render(list, math.max(1, width - 4), {
		expanded = function(root)
			return threads.is_thread_expanded(root, context.expanded_threads)
		end,
		padding_x = 0,
		reaction_options = context.reaction_options,
	})
	local rendered = box.render({ { lines = lines, spans = spans } }, {
		width = width,
		padding_x = 0,
	})
	return utils.virtual_lines(rendered.lines, rendered.highlights)
end

---@param buf integer|nil
function M.clear_comments(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	end
end

---@param buf integer
---@param line integer
---@param count integer
---@param above boolean
function M.pad_comments(buf, line, count, above)
	if not vim.api.nvim_buf_is_valid(buf) or count <= 0 then
		return
	end
	local virtual_lines = {}
	for _ = 1, count do
		table.insert(virtual_lines, { { "", "Normal" } })
	end
	vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
		virt_lines = virtual_lines,
		virt_lines_above = above,
		virt_lines_leftcol = true,
		priority = 1090,
	})
end

---@class AtlasCommentRendererOptions
---@field above_lines table<integer, boolean>

---@param context AtlasCommentRendererContext
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
---@param opts AtlasCommentRendererOptions
---@return table<integer, integer>
function M.render_comments(context, buf, by_line, opts)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	M.clear_comments(buf)
	local sizes = {}
	local line_count = vim.api.nvim_buf_line_count(buf)
	for line, list in pairs(by_line) do
		if line >= 1 and line <= line_count then
			local marked = {}
			for _, node in ipairs(list) do
				local inline = node.comment.inline
				local start_line = inline and (inline.to and inline.start_to or inline.start_from)
				for range_line = start_line or line, line - 1 do
					if range_line >= 1 and not marked[range_line] then
						marked[range_line] = true
						vim.api.nvim_buf_set_extmark(buf, namespace, range_line - 1, 0, {
							number_hl_group = "CursorLineNr",
							sign_text = "┃",
							sign_hl_group = "AtlasLogInfo",
							priority = 1100,
						})
					end
				end
			end
			local virtual_lines = M.thread_lines(context, buf, list)
			sizes[line] = #virtual_lines
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				virt_lines = virtual_lines,
				virt_lines_above = opts.above_lines[line] == true,
				virt_lines_leftcol = true,
				number_hl_group = "CursorLineNr",
				sign_text = "┃",
				sign_hl_group = "AtlasLogInfo",
				priority = 1100,
			})
		end
	end
	return sizes
end

return M
