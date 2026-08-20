--TODO: Holy complex fuck pls refactor
local M = {}

local threadsv2 = require("atlas.ui.components.threadsv2")
local code_preview = require("atlas.ui.components.code_preview")
local emojis = require("atlas.ui.shared.emojis")
local highlights = require("atlas.ui.shared.highlights")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local SUGGESTION_PATTERN = "^(.-)```suggestion[^\n]*\n(.-)\n```(.*)$"

---@alias AtlasReviewThreadAction "add_comment"|"edit"|"delete"|"toggle_task"|"toggle_resolved"

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

---@param author PullsAuthor|nil
---@return string|nil
local function author_mention(author)
	if author == nil then
		return nil
	end
	local username = tostring(author.nickname or author.username or "")
	if username ~= "" then
		return "@" .. username
	end
	local name = tostring(author.name or "")
	return name ~= "" and name or nil
end

---@param comment PullsComment
---@return string|nil
local function resolution_text(comment)
	if comment.state ~= "RESOLVED" then
		return nil
	end
	local resolver = author_mention(comment.resolved_by)
	if resolver == nil then
		return nil
	end
	local resolved_at = comment.resolved_on and utils.relative_time(comment.resolved_on) or ""
	local text = "resolved by " .. resolver
	if resolved_at ~= "" then
		text = text .. "  " .. resolved_at
	end
	return text
end

---@param text string
---@param marker string
---@param marker_hl string|table[]|nil
---@return string, string|table[]|nil
local function status_text(text, marker, marker_hl)
	if text == "" then
		return marker, marker_hl
	end
	local separator = marker ~= "" and "  " or ""
	local highlights = {
		{ start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" },
	}
	local offset = #text + #separator
	if type(marker_hl) == "table" then
		for _, highlight in ipairs(marker_hl) do
			table.insert(highlights, {
				start_col = offset + highlight.start_col,
				end_col = offset + highlight.end_col,
				hl_group = highlight.hl_group,
			})
		end
	elseif marker ~= "" and marker_hl then
		table.insert(highlights, {
			start_col = offset,
			end_col = offset + #marker,
			hl_group = marker_hl,
		})
	end
	return text .. separator .. marker, highlights
end

---@param comment PullsComment
---@param marker string
---@param marker_hl string|table[]|nil
---@return string, string|table[]|nil
local function resolution_status(comment, marker, marker_hl)
	return status_text(resolution_text(comment) or "", marker, marker_hl)
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
---@return string text, string|table[] hl
function M.status_marker(comment)
	if comment.state == "DELETED" then
		return icons.general("delete")
	end
	if comment.state == "PENDING" then
		return icons.pulls_status("inprogress")
	end

	local resolved = comment.state == "RESOLVED"
	local outdated = comment.outdated == true or comment.state == "OUTDATED"
	if resolved and outdated then
		local resolved_icon, resolved_hl = icons.general("success")
		local outdated_icon, outdated_hl = icons.general("progress")
		return resolved_icon .. " " .. outdated_icon,
			{
				{ start_col = 0, end_col = #resolved_icon, hl_group = resolved_hl },
				{
					start_col = #resolved_icon + 1,
					end_col = #resolved_icon + 1 + #outdated_icon,
					hl_group = outdated_hl,
				},
			}
	end
	if resolved then
		return icons.general("success")
	end
	if outdated then
		return icons.general("progress")
	end
	return "", "AtlasTextMuted"
end

---@param comment PullsComment
---@return string|nil, AtlasThreadContentBlock|nil
local function suggestion_content(comment)
	if not comment.inline then
		return nil, nil
	end
	local raw = tostring(comment.content_raw or ""):gsub("\r\n", "\n")
	local before, replacement, after = raw:match(SUGGESTION_PATTERN)
	if replacement == nil then
		return nil, nil
	end

	local prose = utils.strip_markup(before)
	local trailing = utils.strip_markup(after)
	if trailing ~= "" then
		prose = prose ~= "" and (prose .. "\n\n" .. trailing) or trailing
	end
	local start_line = comment.inline.start_to or comment.inline.to or 1
	local lines = vim.split(replacement, "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	local preview = code_preview.render({
		file_path = comment.inline.path,
		lines = lines,
		start_line = start_line,
		show_line_numbers = false,
		background_hl_group = "AtlasDiffChangeLine",
	})
	return prose ~= "" and prose or nil,
		{
			title = "Suggestion",
			lines = preview.lines,
			highlights = preview.highlights,
		}
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
		local edit_key = is_root and opts.action_keys and opts.action_keys.edit
		if edit_key then
			table.insert(footer_items, {
				text = edit_key .. " edit",
				hl_group = "AtlasTextMuted",
			})
		end
		local delete_key = is_root and opts.action_keys and opts.action_keys.delete
		if delete_key then
			table.insert(footer_items, {
				text = delete_key .. " delete",
				hl_group = "AtlasTextMuted",
			})
		end
		if is_root and opts.toggle_resolved_key then
			table.insert(footer_items, {
				text = opts.toggle_resolved_key .. (is_resolved and " reopen" or " complete"),
				hl_group = "AtlasTextMuted",
			})
		end

		local user_icon, user_icon_hl = icons.general("user")
		local marker, marker_hl = M.status_marker(comment)
		marker, marker_hl = resolution_status(comment, marker, marker_hl)
		return {
			icon = user_icon,
			icon_hl = user_icon_hl,
			author = creator,
			additional = additional,
			right_text = marker,
			content = string.format("%s %s", checkbox, title),
			footer_items = footer_items,
			children = {},
			line_map = { comment = comment, entity_kind = "task" },
			meta = {
				comment = comment,
				author_hl_name = creator,
				is_task = true,
				is_resolved = is_resolved,
				right_text_hl = marker_hl,
			},
		}
	end

	local text, content_block
	if is_deleted then
		text = "(deleted comment)"
	else
		text, content_block = suggestion_content(comment)
		if not content_block then
			text = utils.strip_markup(comment.content_display or comment.content_raw or "")
		end
	end
	if text == "" and not content_block then
		text = "(empty comment)"
	end

	local author = author_name(comment.author)
	local footer_items = {}
	if opts.show_reactions ~= false then
		local reactions, reaction_highlights = emojis.format(comment.reactions, opts.reaction_options)
		if reactions ~= "" then
			table.insert(footer_items, { text = reactions, highlights = reaction_highlights })
		end
	end

	if is_root and opts.action_keys then
		local actions = {
			{ key = "reply", label = "reply" },
			{ key = "edit", label = "edit" },
			{ key = "delete", label = "delete" },
		}
		for _, action in ipairs(actions) do
			local key = opts.action_keys[action.key]
			if key then
				table.insert(footer_items, {
					text = string.format("%s %s", key, action.label),
					hl_group = "AtlasTextMuted",
				})
			end
		end
		local toggle_key = opts.action_keys.toggle_resolved
		if toggle_key then
			table.insert(footer_items, {
				text = string.format("%s %s", toggle_key, is_resolved and "reopen" or "resolve"),
				hl_group = "AtlasTextMuted",
			})
		end
	end

	local marker, marker_hl
	if is_root then
		marker, marker_hl = M.status_marker(comment)
		marker, marker_hl = resolution_status(comment, marker, marker_hl)
	end
	local user_icon, user_icon_hl = icons.general("user")
	local additional = utils.relative_time(comment.created_on)
	local location = is_root and opts.location and opts.location(comment) or ""
	if location ~= "" then
		additional = additional ~= "" and (additional .. "  " .. location) or location
	end

	return {
		icon = user_icon,
		icon_hl = user_icon_hl,
		author = tostring(author),
		additional = additional,
		right_text = marker,
		content = text,
		content_block = content_block,
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
---@param opts AtlasReviewThreadRenderOptions
---@return AtlasThreadV2RenderOpts
local function threads_opts(padding_x, opts)
	local content_max_lines = opts.content_max_lines
	if type(content_max_lines) == "function" then
		local callback = content_max_lines
		content_max_lines = function(item)
			local comment = item.line_map and item.line_map.comment or nil
			return comment and callback(comment) or nil
		end
	end

	return {
		padding_x = padding_x,
		separator = "─",
		content_max_lines = content_max_lines,
		content_truncated_key = opts.content_truncated_key,
		content_prefix = opts.content_prefix,
		additional_hl = function(item)
			return item.meta.additional_hl or "AtlasTextMuted"
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
			local segments = {}
			if meta.is_task == true then
				local checkbox_start, checkbox_end = row:find("%[[ xX]%]")
				if checkbox_start then
					table.insert(segments, {
						start_col = checkbox_start - 1,
						end_col = checkbox_end,
						hl_group = meta.is_resolved and "AtlasTextPositive" or "AtlasTextMuted",
					})
				end
			elseif meta.is_deleted then
				table.insert(segments, { start_col = 0, end_col = #row, hl_group = "AtlasTextMutedItalic" })
			end
			return #segments > 0 and segments or nil
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
---@param expanded table<string, boolean>
---@return boolean
function M.is_thread_expanded(comment, expanded)
	if comment.is_task then
		return true
	end
	return expanded[M.comment_key(comment)] == true
end

---@param node AtlasReviewThreadNode
---@return boolean
local function is_collapsible(node)
	return not node.comment.is_task and (#node.children > 0 or node.comment.state == "RESOLVED")
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
		local key = M.comment_key(node.comment)
		expanded[key] = should_expand or nil
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
	item.line_map.thread_has_replies = not is_root or #node.children > 0
	if is_root and not node.comment.is_task and not opts.expanded(node.comment) then
		item.children = {}
		if node.comment.state == "RESOLVED" then
			item.content = nil
			item.content_block = nil
			item.footer_items = {}
		elseif #node.children > 0 then
			local count = descendant_count(node)
			local label = string.format("%d %s", count, count == 1 and "reply" or "replies")
			table.insert(item.footer_items, { text = label, hl_group = "AtlasLogInfo" })
		end
		return item
	end
	item.children = {}
	for _, child in ipairs(node.children) do
		table.insert(item.children, build_item(child, opts, false, root))
	end
	return item
end

---@class AtlasReviewThreadActionKeys
---@field reply? string
---@field edit? string
---@field delete? string
---@field toggle_resolved? string

---@class AtlasReviewThreadRenderOptions
---@field expanded? fun(root: PullsComment): boolean
---@field action_keys? AtlasReviewThreadActionKeys
---@field padding_x? integer
---@field toggle_resolved_key? string
---@field reaction_options? PullsReactionOption[]
---@field show_reactions? boolean
---@field location? fun(comment: PullsComment): string
---@field content_prefix? string
---@field content_max_lines? integer|fun(comment: PullsComment): integer|nil
---@field content_truncated_key? string

---@param nodes AtlasReviewThreadNode[]
---@param width integer
---@param opts AtlasReviewThreadRenderOptions|nil
---@return string[], table[], table<integer, table>
function M.render(nodes, width, opts)
	opts = opts or {}
	opts.expanded = opts.expanded or function()
		return true
	end
	local rendered = {}
	for _, node in ipairs(nodes or {}) do
		table.insert(rendered, build_item(node, opts, true, nil))
	end
	return threadsv2.render(rendered, width, threads_opts(opts.padding_x or 1, opts))
end

---@param node AtlasReviewThreadNode
---@param width integer
---@param opts AtlasReviewThreadRenderOptions|nil
---@return string[], table[], table<integer, table>
function M.render_task_compact(node, width, opts)
	opts = opts or {}
	opts.expanded = function()
		return true
	end
	local item = build_item(node, opts, true, nil)
	local task = node.comment
	local label = tostring(task.task_label or "")
	item.additional = label ~= "" and label or "added a task"
	local timestamp = utils.relative_time(task.created_on)
	if timestamp ~= "" then
		item.additional = item.additional .. "  " .. timestamp
	end
	return threadsv2.render({ item }, width, threads_opts(opts.padding_x or 1, opts))
end

---@param node AtlasReviewThreadNode
---@param width integer
---@param expanded boolean
---@param location string
---@param opts AtlasReviewThreadRenderOptions|nil
---@return string[], AtlasUIHighlight[], table<integer, table>
function M.render_compact(node, width, expanded, location, opts)
	opts = opts or {}
	opts.expanded = function()
		return true
	end
	local item = build_item(node, opts, true, nil)

	local comment = node.comment
	local replies = descendant_count(node)
	local marker, marker_hl = M.status_marker(comment)
	local fields = {
		{ text = location, hl = "Normal" },
		{ text = utils.relative_time(comment.created_on), hl = "AtlasTextMuted" },
		{
			text = replies > 0 and string.format("%d %s", replies, replies == 1 and "reply" or "replies") or "",
			hl = "AtlasTextMuted",
		},
	}
	local metadata, metadata_hl = "", {}
	for _, field in ipairs(fields) do
		if field.text ~= "" then
			if metadata ~= "" then
				metadata = metadata .. "  "
			end
			local start_col = #metadata
			metadata = metadata .. field.text
			if type(field.hl) == "table" then
				for _, highlight in ipairs(field.hl) do
					table.insert(metadata_hl, {
						start_col = start_col + highlight.start_col,
						end_col = start_col + highlight.end_col,
						hl_group = highlight.hl_group,
					})
				end
			else
				table.insert(metadata_hl, { start_col = start_col, end_col = #metadata, hl_group = field.hl })
			end
		end
	end

	local expander, expander_hl = icons.general(expanded and "fold_open" or "fold_closed")
	item.icon = expander
	item.icon_hl = expander_hl
	item.author = "@" .. author_name(comment.author)
	item.additional = metadata
	item.right_text, item.meta.right_text_hl = resolution_status(comment, marker, marker_hl)
	item.line_map.tree_key = M.comment_key(comment)
	item.meta.additional_hl = metadata_hl
	if not expanded then
		item.content = nil
		item.content_block = nil
		item.children = {}
		item.footer_items = {}
	end

	return threadsv2.render({ item }, math.max(1, width - 2), threads_opts(0, opts))
end

---@param comment PullsComment
---@param width integer
---@return AtlasMarkdownEditorPreview
function M.render_comment(comment, width)
	local lines, spans = M.render({ { comment = comment, children = {} } }, width, { padding_x = 1 })
	return { lines = lines, highlights = spans }
end

return M
