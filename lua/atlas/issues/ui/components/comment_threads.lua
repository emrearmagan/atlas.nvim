local M = {}

local threadsv2 = require("atlas.ui.components.threadsv2")
local emojis = require("atlas.ui.shared.emojis")
local helper = require("atlas.issues.ui.main.helper")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@param author IssueUser|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.display_name and author.display_name ~= "" then
		return author.display_name
	end
	if author.account_id and author.account_id ~= "" then
		return author.account_id
	end
	return "Unknown"
end

---@param comment IssueComment
---@param reaction_options IssueReactionOption[]|nil
---@return AtlasThreadV2Item
local function comment_item(comment, reaction_options)
	local deleted = comment.deleted == true
	local content = deleted and "(deleted comment)" or utils.strip_markup(comment.body or "")
	if content == "" then
		content = "(empty comment)"
	end

	local footer_items = {}
	local reactions, reaction_highlights = emojis.format(comment.reactions, reaction_options)
	if reactions ~= "" then
		table.insert(footer_items, { text = reactions, highlights = reaction_highlights })
	end

	local author = author_name(comment.author)
	local user_icon = icons.general("user")
	return {
		icon = user_icon,
		author = author,
		additional = utils.relative_time(comment.created),
		content = content,
		footer_items = footer_items,
		children = {},
		line_map = { comment = comment, entity_kind = "comment" },
		meta = { author = author, deleted = deleted },
	}
end

---@param padding_x integer
---@param opts IssuesCommentThreadRenderOptions
---@return AtlasThreadV2RenderOpts
local function render_options(padding_x, opts)
	local max_lines = opts.content_max_lines
	if type(max_lines) == "function" then
		local callback = max_lines
		max_lines = function(item)
			local comment = item.line_map and item.line_map.comment
			return comment and callback(comment) or nil
		end
	end

	return {
		padding_x = padding_x,
		content_max_lines = max_lines,
		content_truncated_key = opts.content_truncated_key,
		author_hl = function(item)
			return helper.person_hl(item.meta.author)
		end,
		icon_hl_fn = function(item)
			return helper.person_hl(item.meta.author)
		end,
		additional_hl = function()
			return "AtlasTextMuted"
		end,
		content_hl = function(item, row)
			if item.meta.deleted then
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedItalic" } }
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
			local left_date = tostring(left.comment.created or "")
			local right_date = tostring(right.comment.created or "")
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
---@return AtlasThreadV2Item
local function build_item(node, opts, root)
	root = root or node.comment
	local item = comment_item(node.comment, opts.reaction_options)
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
---@field reaction_options IssueReactionOption[]|nil
---@field content_max_lines integer|fun(comment: IssueComment): integer|nil
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
	return threadsv2.render(items, width, render_options(opts.padding_x or 1, opts))
end

---@param comment IssueComment
---@param width integer
---@return AtlasMarkdownEditorPreview
function M.render_comment(comment, width)
	local lines, highlights = M.render({ { comment = comment, children = {} } }, width, {
		expanded = function()
			return true
		end,
	})
	return { lines = lines, highlights = highlights }
end

return M
