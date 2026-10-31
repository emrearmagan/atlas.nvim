local M = {}

local threads = require("atlas.ui.components.threads")
local helper = require("atlas.issues.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@param comment IssueComment
---@return AtlasThreadItem
local function comment_item(comment)
	local deleted = comment.deleted == true
	local content = deleted and "(deleted comment)" or (comment.body_display or comment.body or "")
	if content == "" then
		content = "(empty comment)"
	end

	local author = helper.person_name(comment.author)
	local author_hl = helper.person_hl(author)
	local user_icon = icons.get("user")
	local item = {
		icon = user_icon,
		icon_hl = author_hl,
		author = author,
		author_hl = author_hl,
		additional = { { table.concat(comment.author_roles or {}, " "), "AtlasTextMuted" } },
		right_text = { { utils.relative_time(comment.created_at), "AtlasTextMuted" } },
		content = content,
		markdown = not deleted,
		footer_items = {},
		children = {},
		line_map = { comment = comment, entity_kind = "comment" },
		meta = { deleted = deleted },
	}

	if not deleted then
		item.reactions = comment.reactions
	end
	return item
end

---@param padding_x integer
---@param max_lines integer|(fun(comment: IssueComment): integer|nil)|nil
---@param truncated_key string|nil
---@return AtlasThreadRenderOpts
local function render_options(padding_x, max_lines, truncated_key)
	if type(max_lines) == "function" then
		local callback = max_lines
		---@param item AtlasThreadItem
		max_lines = function(item)
			local comment = item.line_map and item.line_map.comment
			return comment and callback(comment) or nil
		end
	end

	return {
		padding_x = padding_x,
		content_max_lines = max_lines,
		content_truncated_key = truncated_key,
		content_hl = function(item, row)
			if item.meta.deleted then
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
			end
		end,
	}
end

---@class IssuesCommentThreadNode
---@field comment IssueComment
---@field children IssuesCommentThreadNode[]

---@param comments IssueComment[]
---@return IssuesCommentThreadNode[]
function M.group_comments(comments)
	local nodes = {}
	local by_id = {}
	for _, comment in ipairs(comments) do
		local node = { comment = comment, children = {} }
		table.insert(nodes, node)
		by_id[tostring(comment.id)] = node
	end

	local roots = {}
	for _, node in ipairs(nodes) do
		local parent = node.comment.parent_id and by_id[tostring(node.comment.parent_id)]
		if parent and parent ~= node then
			table.insert(parent.children, node)
		else
			table.insert(roots, node)
		end
	end

	local function sort_tree(items)
		table.sort(items, function(left, right)
			local left_date = tostring(left.comment.created_at or "")
			local right_date = tostring(right.comment.created_at or "")
			if left_date ~= right_date then
				return left_date < right_date
			end
			return tostring(left.comment.id) < tostring(right.comment.id)
		end)
		for _, item in ipairs(items) do
			sort_tree(item.children)
		end
	end

	sort_tree(roots)
	return roots
end

---@param node IssuesCommentThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@param node IssuesCommentThreadNode
---@param opts IssuesCommentThreadRenderOptions
---@param root IssueComment|nil
---@return AtlasThreadItem
local function build_item(node, opts, root)
	root = root or node.comment
	local item = comment_item(node.comment)
	item.line_map.thread_root = root
	item.line_map.thread_has_replies = node.comment ~= root or #node.children > 0

	if node.comment == root and not opts.expanded(root) and #node.children > 0 then
		local count = descendant_count(node)
		table.insert(item.footer_items, {
			text = string.format("%d %s", count, count == 1 and "reply" or "replies"),
			hl_group = "AtlasLogInfo",
		})
		return item
	end

	for _, child in ipairs(node.children) do
		table.insert(item.children, build_item(child, opts, root))
	end
	return item
end

---@class IssuesCommentThreadRenderOptions
---@field expanded fun(root: IssueComment): boolean
---@field padding_x integer|nil
---@field content_max_lines integer|(fun(comment: IssueComment): integer|nil)|nil
---@field content_truncated_key string|nil

---@param nodes IssuesCommentThreadNode[]
---@param width integer
---@param opts IssuesCommentThreadRenderOptions
---@return string[], table[], table<integer, table>
function M.render(nodes, width, opts)
	local items = {}
	for _, node in ipairs(nodes) do
		table.insert(items, build_item(node, opts, nil))
	end
	return threads.render_comments(
		items,
		width,
		render_options(opts.padding_x or 1, opts.content_max_lines, opts.content_truncated_key)
	)
end

---@param comment IssueComment
---@param width integer
---@return AtlasEditorPreview
function M.render_comment(comment, width)
	local lines, highlights = threads.render({ comment_item(comment) }, width, render_options(1, nil, nil))
	return { lines = lines, highlights = highlights }
end

return M
