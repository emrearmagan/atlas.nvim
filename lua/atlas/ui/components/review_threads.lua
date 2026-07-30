local M = {}

local threadsv2 = require("atlas.ui.components.threadsv2")
local highlights = require("atlas.ui.shared.highlights")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@param author { name: string, nickname: string|nil }|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.nickname and author.nickname ~= "" then
		return author.nickname
	end
	if author.name and author.name ~= "" then
		return author.name
	end
	return "Unknown"
end

---@param name string|nil
---@return string
local function author_hl(name)
	local normalized = name and vim.trim(name):lower() or ""
	if normalized == "" or normalized == "unknown" or normalized == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(normalized) or "AtlasTextMuted"
end

---@param comment PullsComment
---@return string|nil text, string|nil hl
local function root_marker(comment)
	if comment.state == "DELETED" then
		local icon, icon_hl = icons.general("delete")
		return icon .. " deleted  ", icon_hl
	end
	if comment.state == "RESOLVED" then
		local icon, icon_hl = icons.general("success")
		return icon .. " resolved  ", icon_hl
	end
	if comment.state == "OUTDATED" then
		local icon, icon_hl = icons.general("warning")
		return icon .. " outdated  ", icon_hl
	end
	if comment.state == "PENDING" then
		local icon, icon_hl = icons.general("warning")
		return icon .. " pending  ", icon_hl
	end
	return nil, nil
end

---@param label string
---@param root AtlasReviewThreadNode
---@return AtlasThreadV2Item
local function summary_item(label, root)
	return {
		icon = "",
		author = label,
		additional = nil,
		right_text = "",
		content = nil,
		children = {},
		footer_items = {},
		line_map = {
			entity_kind = "comment_summary",
			thread_root = root.comment,
			comment = root.comment,
		},
		meta = { is_summary = true },
	}
end

---@param opts AtlasReviewThreadRenderOptions
---@param action AtlasReviewCommentAction
---@param comment PullsComment
---@return boolean
local function can_action(opts, action, comment)
	return opts.can_action ~= nil and opts.can_action(action, comment) == true
end

---@param comment PullsComment
---@param opts AtlasReviewThreadRenderOptions
---@param is_root? boolean
---@return AtlasThreadV2Item
local function comment_item(comment, opts, is_root)
	local is_deleted = comment.state == "DELETED"
	local is_resolved = comment.state == "RESOLVED"

	if comment.is_task then
		local checkbox = is_resolved and "[x]" or "[ ]"
		local title = utils.task_text(comment.content_display or comment.content_raw)
		if title == "" then
			title = "(empty task)"
		end
		local creator = author_name(comment.author)
		local timestamp = utils.relative_time(comment.created_on)
		local additional = timestamp ~= "" and ("TASK  " .. timestamp) or "TASK"
		local footer_items = {}
		if opts.toggle_resolved_key and can_action(opts, "toggle_task", comment) then
			table.insert(
				footer_items,
				string.format(
					"%s (%s)",
					is_resolved and icons.general("refresh") or icons.general("success"),
					opts.toggle_resolved_key
				)
			)
		end
		if can_action(opts, "edit", comment) then
			table.insert(footer_items, string.format("%s (e)", icons.general("edit")))
		end
		if can_action(opts, "delete", comment) then
			table.insert(footer_items, string.format("%s (d)", icons.general("delete")))
		end

		local user_icon, user_icon_hl = icons.general("user")
		return {
			icon = user_icon,
			icon_hl = user_icon_hl,
			author = creator,
			additional = additional,
			right_text = "",
			content = string.format("%s %s", checkbox, title),
			footer_items = footer_items,
			children = {},
			line_map = { comment = comment, entity_kind = "task" },
			meta = {
				comment = comment,
				author_hl_name = creator,
				is_task = true,
				is_resolved = is_resolved,
			},
		}
	end

	local text = is_deleted and "(deleted comment)"
		or utils.strip_markup(comment.content_display or comment.content_raw or "")
	if text == "" then
		text = "(empty comment)"
	end

	local author = author_name(comment.author)
	local footer_items = {}
	if is_root and opts.toggle_resolved_key and can_action(opts, "toggle_resolved", comment) then
		table.insert(
			footer_items,
			string.format(
				"%s (%s)",
				is_resolved and icons.general("refresh") or icons.general("success"),
				opts.toggle_resolved_key
			)
		)
	end
	if can_action(opts, "reply", comment) then
		table.insert(footer_items, string.format("%s (c)", icons.general("reply")))
	end
	if can_action(opts, "edit", comment) then
		table.insert(footer_items, string.format("%s (e)", icons.general("edit")))
	end
	if can_action(opts, "delete", comment) then
		table.insert(footer_items, string.format("%s (d)", icons.general("delete")))
	end

	local marker, marker_hl
	if is_root then
		marker, marker_hl = root_marker(comment)
	end
	local user_icon, user_icon_hl = icons.general("user")

	return {
		icon = user_icon,
		icon_hl = user_icon_hl,
		author = tostring(author),
		additional = utils.relative_time(comment.created_on),
		right_text = marker,
		content = text,
		children = {},
		footer_items = footer_items,
		line_map = { comment = comment, entity_kind = "comment" },
		meta = {
			comment = comment,
			author_hl_name = author,
			is_deleted = is_deleted,
			right_text_hl = marker_hl,
		},
	}
end

---@param padding_x integer
---@return AtlasThreadV2RenderOpts
local function threads_opts(padding_x)
	return {
		padding_x = padding_x,
		separator = "─",
		additional_hl = function(_item)
			return "AtlasTextMuted"
		end,
		author_hl = function(item, author)
			local meta = item and item.meta or nil
			local author_hl_name = meta and meta.author_hl_name or author
			return author_hl(author_hl_name)
		end,
		icon_hl_fn = function(item)
			local meta = item and item.meta or nil
			local author_hl_name = meta and meta.author_hl_name or tostring(item.author or "")
			return author_hl(author_hl_name)
		end,
		content_hl = function(item, row)
			local meta = item and item.meta or {}
			if meta.is_task == true then
				local checkbox = row:match("^%[[ xX]%]")
				if checkbox then
					return {
						{
							start_col = 0,
							end_col = #checkbox,
							hl_group = meta.is_resolved and "AtlasTextPositive" or "AtlasTextMuted",
						},
					}
				end
				return nil
			end
			if meta.is_deleted then
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedItalic" } }
			end
			return nil
		end,
		right_text_hl = function(item)
			local meta = item and item.meta or {}
			return meta.right_text_hl
		end,
	}
end

---@param comment PullsComment
---@return string
function M.comment_key(comment)
	return (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
end

---@param comment PullsComment
---@return string|nil
local function parent_key(comment)
	return comment.parent_id ~= nil and ("comment:" .. tostring(comment.parent_id)) or nil
end

---@param left AtlasReviewThreadNode
---@param right AtlasReviewThreadNode
---@return boolean
local function node_sort(left, right)
	local a = left.comment
	local b = right.comment
	local a_date = tostring(a.created_on or "")
	local b_date = tostring(b.created_on or "")
	if a_date ~= b_date then
		return a_date < b_date
	end
	return tostring(a.id or "") < tostring(b.id or "")
end

---@class AtlasReviewThreadNode
---@field comment PullsComment
---@field children AtlasReviewThreadNode[]

---@param comments PullsComment[]
---@param tasks? PullsComment[]
---@return AtlasReviewThreadNode[]
function M.group_comments(comments, tasks)
	if tasks ~= nil then
		local comment_ids = {}
		local review_items = vim.list_extend({}, comments or {})
		for _, comment in ipairs(comments or {}) do
			comment_ids[tostring(comment.id)] = true
		end
		for _, task in ipairs(tasks) do
			local parent_id = task.parent_id and tostring(task.parent_id) or nil
			if parent_id and comment_ids[parent_id] then
				table.insert(review_items, task)
			end
		end
		comments = review_items
	end

	local nodes, by_id = {}, {}
	for _, comment in ipairs(comments or {}) do
		local node = { comment = comment, children = {} }
		table.insert(nodes, node)
		by_id[M.comment_key(comment)] = node
	end

	local roots = {}
	for _, node in ipairs(nodes) do
		local parent = by_id[parent_key(node.comment) or ""]
		if parent and parent ~= node then
			table.insert(parent.children, node)
		else
			table.insert(roots, node)
		end
	end

	local function sort_tree(list)
		table.sort(list, node_sort)
		for _, node in ipairs(list) do
			sort_tree(node.children)
		end
	end
	sort_tree(roots)
	return roots
end

---@param node AtlasReviewThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@param comment PullsComment
---@return boolean
local function collapsed_by_default(comment)
	return not comment.is_task and (comment.state == "RESOLVED" or comment.state == "OUTDATED")
end

---@param comment PullsComment
---@param expanded table<string, boolean>
---@return boolean
function M.is_thread_expanded(comment, expanded)
	if comment.is_task then
		return true
	end
	local value = expanded[M.comment_key(comment)]
	if value ~= nil then
		return value
	end
	return not collapsed_by_default(comment)
end

---@param node AtlasReviewThreadNode
---@return boolean
local function is_collapsible(node)
	return not node.comment.is_task
end

---@param nodes AtlasReviewThreadNode[]
---@param expanded table<string, boolean>
---@return boolean toggled, boolean expanded_all
function M.toggle_all_threads(nodes, expanded)
	local collapsible = {}
	local should_expand = false
	for _, node in ipairs(nodes) do
		if is_collapsible(node) then
			table.insert(collapsible, node)
			if not M.is_thread_expanded(node.comment, expanded) then
				should_expand = true
			end
		end
	end
	for _, node in ipairs(collapsible) do
		local default_expanded = not collapsed_by_default(node.comment)
		local key = M.comment_key(node.comment)
		if should_expand == default_expanded then
			expanded[key] = nil
		else
			expanded[key] = should_expand
		end
	end
	return #collapsible > 0, should_expand
end

---@param node AtlasReviewThreadNode
---@param opts AtlasReviewThreadRenderOptions
---@param is_root boolean
---@param root PullsComment|nil
---@return AtlasThreadV2Item
local function build_item(node, opts, is_root, root)
	root = root or node.comment
	local item = comment_item(node.comment, opts, is_root)
	item.line_map.thread_root = root
	if is_root and not node.comment.is_task and not opts.expanded(node.comment) then
		item.additional = nil
		item.content = nil
		item.footer_items = {}
		item.children = {}
		if not collapsed_by_default(node.comment) and #node.children > 0 then
			local count = descendant_count(node)
			local label = string.format("%d %s", count, count == 1 and "reply" or "replies")
			item.children = { summary_item(label, node) }
		end
		return item
	end
	item.children = {}
	for _, child in ipairs(node.children) do
		table.insert(item.children, build_item(child, opts, false, root))
	end
	return item
end

---@class AtlasReviewThreadRenderOptions
---@field expanded? fun(root: PullsComment): boolean
---@field can_action? fun(action: AtlasReviewCommentAction, comment: PullsComment): boolean
---@field padding_x? integer
---@field toggle_resolved_key? string

---@param nodes AtlasReviewThreadNode[]
---@param width integer
---@param opts AtlasReviewThreadRenderOptions|nil
---@return string[], table[], table<integer, table>
function M.render_threads(nodes, width, opts)
	opts = opts or {}
	opts.expanded = opts.expanded or function()
		return true
	end
	local rendered = {}
	for _, node in ipairs(nodes or {}) do
		table.insert(rendered, build_item(node, opts, true, nil))
	end
	return threadsv2.render(rendered, width, threads_opts(opts.padding_x or 1))
end

return M
