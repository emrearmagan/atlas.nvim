local M = {}

local box = require("atlas.ui.components.box")
local icons = require("atlas.ui.shared.icons")
local threads = require("atlas.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")

local namespace = vim.api.nvim_create_namespace("atlas_review_comments")
local comment_icon, comment_icon_hl = icons.general("comment")

---@class AtlasCommentOverlayContext
---@field threads AtlasReviewThreadNode[]
---@field expanded_threads table<string, boolean>
---@field old_path string
---@field new_path string

---@param context AtlasCommentOverlayContext
---@param comment PullsComment
---@param path string
---@param side "LEFT"|"RIGHT"
---@return boolean
local function matches(context, comment, path, side)
	local inline = comment.inline
	if inline == nil then
		return false
	end

	local matches_path = inline.path == path
	if not matches_path then
		local path_is_current = path == context.old_path or path == context.new_path
		matches_path = path_is_current and (inline.path == context.old_path or inline.path == context.new_path)
	end
	if not matches_path then
		return false
	end

	if side == "RIGHT" then
		return inline.to ~= nil
	end
	return inline.to == nil and inline.from ~= nil
end

---@param context AtlasCommentOverlayContext
---@param path string
---@param side "LEFT"|"RIGHT"
---@return table<integer, AtlasReviewThreadNode[]>
function M.threads_by_line(context, path, side)
	local result = {}
	for _, node in ipairs(context.threads) do
		local comment = node.comment
		if matches(context, comment, path, side) then
			local line = side == "LEFT" and comment.inline.from or comment.inline.to
			if line then
				result[line] = result[line] or {}
				table.insert(result[line], node)
			end
		end
	end
	return result
end

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

---@class AtlasCommentOverlayOptions
---@field above_lines? table<integer, boolean>

---@param context AtlasCommentOverlayContext
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
---@param opts? AtlasCommentOverlayOptions
---@return table<integer, integer>
function M.render_comments(context, buf, by_line, opts)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	M.clear_comments(buf)
	opts = opts or {}
	local sizes = {}
	local line_count = vim.api.nvim_buf_line_count(buf)
	local width = buffer_width(buf)
	for line, list in pairs(by_line) do
		if line >= 1 and line <= line_count then
			local lines, spans = threads.render_threads(list, math.max(1, width - 3), {
				expanded = function(root)
					return threads.is_thread_expanded(root, context.expanded_threads)
				end,
				padding_x = 0,
			})
			local rendered = box.render({ { lines = lines, spans = spans } }, {
				width = width,
				padding_x = 0,
			})
			local virtual_lines = utils.virtual_lines(rendered.lines, rendered.highlights)
			sizes[line] = #virtual_lines
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				virt_lines = virtual_lines,
				virt_lines_above = opts.above_lines ~= nil and opts.above_lines[line] == true,
				virt_lines_leftcol = true,
				sign_text = comment_icon,
				sign_hl_group = comment_icon_hl,
				priority = 1100,
			})
		end
	end
	return sizes
end

return M
