--TODO: Holy complex fuck pls refactor
local M = {}

local threads = require("atlas.ui.components.threads")
local emojis = require("atlas.ui.shared.emojis")
local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

---@alias AtlasCommentThreadAction "add_comment"|"add_task"|"edit"|"delete"|"toggle_task"|"toggle_resolved"

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

---@param comment PullsComment
---@return [string, string][]
local function comment_status(comment)
	local chunks = {}
	local resolution = resolution_text(comment)
	if resolution then
		chunks[#chunks + 1] = { resolution, "AtlasTextMuted" }
	end

	local outdated = comment.outdated == true or comment.state == "OUTDATED"
	if outdated then
		if #chunks > 0 then
			chunks[#chunks + 1] = { "  ", "AtlasTextMuted" }
		end
		chunks[#chunks + 1] = { "outdated", "AtlasTextWarning" }
	end

	local markers = M.status_marker(comment)
	if #chunks > 0 and #markers > 0 then
		chunks[#chunks + 1] = { "  ", "AtlasTextMuted" }
	end
	return vim.list_extend(chunks, markers)
end

---@param comment PullsComment
---@return [string, string][]
function M.status_marker(comment)
	if comment.state == "DELETED" then
		return { { icons.general("delete") } }
	end

	local chunks = {}
	if comment.pending then
		chunks[#chunks + 1] = { icons.pulls_status("inprogress") }
	end
	if comment.state == "RESOLVED" then
		if #chunks > 0 then
			chunks[#chunks + 1] = { " ", "AtlasTextMuted" }
		end
		chunks[#chunks + 1] = { icons.general("success") }
	end
	if comment.outdated == true or comment.state == "OUTDATED" then
		if #chunks > 0 then
			chunks[#chunks + 1] = { " ", "AtlasTextMuted" }
		end
		local icon = icons.general("progress")
		chunks[#chunks + 1] = { icon, "AtlasTextWarning" }
	end
	return chunks
end

---@param comment PullsComment
---@param opts AtlasCommentThreadRenderOptions
---@param is_root? boolean
---@return AtlasThreadItem
local function comment_item(comment, opts, is_root)
	local is_deleted = comment.state == "DELETED"
	local is_resolved = comment.state == "RESOLVED"
	local author = author_name(comment.author)
	local author_hl = presentation.author_hl(author)
	local user_icon = icons.general("user")
	local additional = utils.relative_time(comment.created_on)
	local location = is_root and opts.location and opts.location(comment) or ""
	if location ~= "" then
		additional = additional .. "  " .. location
	end
	if comment.is_task then
		additional = "TASK  " .. additional
	end

	local footer_items = {}
	local item = {
		icon = user_icon,
		icon_hl = author_hl,
		author = author,
		author_hl = author_hl,
		additional = { { additional, "AtlasTextMuted" } },
		children = {},
		footer_items = footer_items,
		line_map = { comment = comment, entity_kind = comment.is_task and "task" or "comment" },
		meta = {},
	}
	if comment.is_task or is_root then
		item.right_text = comment_status(comment)
	end

	local text = comment.content_raw or ""
	if opts.format_text then
		text = opts.format_text(text)
	end

	if comment.is_task then
		local checkbox = is_resolved and "[x]" or "[ ]"
		local title = utils.task_text(text)
		if title == "" then
			title = "(empty task)"
		end
		item.content = string.format("%s %s", checkbox, title)
		item.meta.is_task = true
		item.meta.is_resolved = is_resolved
	else
		text = is_deleted and "(deleted comment)" or text
		if text == "" then
			text = "(empty comment)"
		end

		item.content = text
		item.markdown = not is_deleted
		item.file_path = comment.inline and comment.inline.path
		item.language_aliases = comment.inline
			and { suggestion = vim.filetype.match({ filename = comment.inline.path }) }
		item.meta.is_deleted = is_deleted

		local reactions, reaction_highlights = emojis.format(comment.reactions, opts.reaction_options)
		if reactions ~= "" then
			table.insert(footer_items, { text = reactions, highlights = reaction_highlights })
		end
	end

	if is_root and opts.action_keys then
		local actions = comment.is_task and { "edit", "delete" } or { "reply", "edit", "delete" }
		for _, action in ipairs(actions) do
			local key = opts.action_keys[action]
			if key then
				table.insert(footer_items, {
					text = key .. " " .. action,
					hl_group = "AtlasTextMuted",
				})
			end
		end
		if not comment.is_task and opts.action_keys.add_task then
			table.insert(footer_items, {
				text = opts.action_keys.add_task .. " task",
				hl_group = "AtlasTextMuted",
			})
		end
		local toggle_key = opts.action_keys.toggle_resolved
		if toggle_key then
			local label = is_resolved and "reopen" or (comment.is_task and "complete" or "resolve")
			table.insert(footer_items, {
				text = toggle_key .. " " .. label,
				hl_group = "AtlasTextMuted",
			})
		end
	end

	return item
end

---@param padding_x integer
---@param opts AtlasCommentThreadRenderOptions
---@return AtlasThreadRenderOpts
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
		show_connectors = false,
		content_max_lines = content_max_lines,
		content_truncated_key = opts.content_truncated_key,
		content_prefix = opts.content_prefix,
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
				table.insert(segments, { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" })
			end
			return #segments > 0 and segments or nil
		end,
	}
end

---@param comment PullsComment
---@return string
function M.comment_key(comment)
	return (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
end

---@param node AtlasCommentThreadNode
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

---@param node AtlasCommentThreadNode
---@return boolean
local function is_collapsible(node)
	return not node.comment.is_task
		and (
			#node.children > 0
			or node.comment.state == "RESOLVED"
			or node.comment.state == "OUTDATED"
			or node.comment.outdated == true
		)
end

---@param nodes AtlasCommentThreadNode[]
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

---@param node AtlasCommentThreadNode
---@param opts AtlasCommentThreadRenderOptions
---@param is_root boolean
---@param root PullsComment|nil
---@return AtlasThreadItem
local function build_item(node, opts, is_root, root)
	root = root or node.comment
	local item = comment_item(node.comment, opts, is_root)
	item.line_map.thread_root = root
	item.line_map.thread_has_replies = not is_root or #node.children > 0
	if is_root and not node.comment.is_task and opts.expanded and not opts.expanded(node.comment) then
		item.children = {}
		if node.comment.state == "RESOLVED" or node.comment.state == "OUTDATED" or node.comment.outdated == true then
			item.content = nil
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

---@class AtlasCommentThreadActionKeys
---@field reply? string
---@field add_task? string
---@field edit? string
---@field delete? string
---@field toggle_resolved? string

---@class AtlasCommentThreadRenderOptions
---@field expanded? fun(root: PullsComment): boolean
---@field action_keys? AtlasCommentThreadActionKeys
---@field padding_x? integer
---@field boxed? boolean
---@field reaction_options? PullsReactionOption[]
---@field location? fun(comment: PullsComment): string
---@field content_prefix? string
---@field content_max_lines? integer|fun(comment: PullsComment): integer|nil
---@field content_truncated_key? string
---@field show_task_label? boolean
---@field format_text? fun(text: string): string

---@param nodes AtlasCommentThreadNode[]
---@param width integer
---@param opts AtlasCommentThreadRenderOptions|nil
---@return string[], table[], table<integer, table>
function M.render(nodes, width, opts)
	opts = opts or {}
	local rendered = {}
	for _, node in ipairs(nodes or {}) do
		table.insert(rendered, build_item(node, opts, true, nil))
	end
	local render = opts.boxed and threads.render_comments or threads.render
	return render(rendered, width, threads_opts(opts.padding_x or 1, opts))
end

---@param node AtlasCommentThreadNode
---@param width integer
---@param opts AtlasCommentThreadRenderOptions|nil
---@return string[], table[], table<integer, table>
function M.render_task_compact(node, width, opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	opts.expanded = nil
	local item = build_item(node, opts, true, nil)
	local task = node.comment
	local label = tostring(task.task_label or "")
	local additional = opts.show_task_label == false and "" or (label ~= "" and label or "added a task")
	local timestamp = utils.relative_time(task.created_on)
	additional = additional ~= "" and (additional .. "  " .. timestamp) or timestamp
	item.additional = { { additional, "AtlasTextMuted" } }
	return threads.render({ item }, width, threads_opts(opts.padding_x or 1, opts))
end

---@param node AtlasCommentThreadNode
---@param width integer
---@param expanded boolean
---@param location string
---@param opts AtlasCommentThreadRenderOptions|nil
---@return string[], AtlasUIHighlight[], table<integer, table>
function M.render_compact(node, width, expanded, location, opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	opts.expanded = nil
	local comment = node.comment
	local item
	if expanded then
		item = build_item(node, opts, true, nil)
	else
		item = comment_item(comment, opts, true)
		item.line_map.thread_root = comment
		item.line_map.thread_has_replies = #node.children > 0
		item.content = nil
		item.footer_items = {}
	end
	local replies = descendant_count(node)
	local fields = {
		{ location, "Normal" },
		{ utils.relative_time(comment.created_on), "AtlasTextMuted" },
		{
			replies > 0 and string.format("%d %s", replies, replies == 1 and "reply" or "replies") or "",
			"AtlasTextMuted",
		},
	}
	item.additional = {}
	for _, field in ipairs(fields) do
		if field[1] ~= "" then
			if #item.additional > 0 then
				item.additional[#item.additional + 1] = { "  ", "AtlasTextMuted" }
			end
			item.additional[#item.additional + 1] = field
		end
	end

	local expander = icons.general(expanded and "fold_open" or "fold_closed")
	item.icon = expander
	item.author = "@" .. author_name(comment.author)
	item.line_map.tree_key = M.comment_key(comment)
	return threads.render({ item }, math.max(1, width - 2), threads_opts(0, opts))
end

---@param comment PullsComment
---@param width integer
---@param format_text (fun(text: string): string)|nil
---@return AtlasEditorPreview
function M.render_comment(comment, width, format_text)
	local lines, spans = M.render({ { comment = comment, children = {} } }, width, {
		padding_x = 1,
		format_text = format_text,
	})
	return { lines = lines, highlights = spans }
end

return M
