local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

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

---@param comment PullsComment
---@param current_user PullsUser|nil
---@return boolean
local function is_own_comment(comment, current_user)
	if not current_user or not comment.author then
		return false
	end
	local cid = tostring(comment.author.id or "")
	local uid = tostring(current_user.id or "")
	return cid ~= "" and uid ~= "" and cid == uid
end

---@param comment PullsComment
---@return string|nil text, string|nil hl
local function root_marker(comment)
	if comment.state == "DELETED" then
		return icons.general("delete") .. " deleted  ", "AtlasLogError"
	end
	if comment.state == "RESOLVED" then
		return icons.general("success") .. " resolved  ", "AtlasTextPositive"
	end
	if comment.state == "OUTDATED" then
		return icons.general("warning") .. " outdated  ", "AtlasLogWarn"
	end
	return nil, nil
end

---@param label string
---@param root PullsComment|nil
---@return AtlasThreadV2Item
function M.summary_item(label, root)
	return {
		icon = "",
		author = label,
		additional = "za to expand",
		right_text = "",
		content = nil,
		children = {},
		footer_items = {},
		line_map = { entity_kind = "comment_summary", thread_root = root, comment = root },
		meta = { is_summary = true },
	}
end

---@param comment PullsComment
---@param replies PullsComment[]|nil
---@param current_user PullsUser|nil
---@param is_root? boolean
---@return AtlasThreadV2Item
function M.comment_item(comment, replies, current_user, is_root)
	local is_deleted = comment.state == "DELETED"
	local is_resolved = comment.state == "RESOLVED"

	local children = {}
	for _, reply in ipairs(replies or {}) do
		table.insert(children, M.comment_item(reply, nil, current_user, false))
	end

	if comment.is_task then
		local checkbox = is_resolved and "[x]" or "[ ]"
		local title = utils.strip_markup(comment.content_raw or "")
		if title == "" then
			title = "(empty task)"
		end
		local first_nl = title:find("\n", 1, true)
		local heading = first_nl and title:sub(1, first_nl - 1) or title
		local creator = author_name(comment.author)

		local actions = {
			string.format("%s (t)", is_resolved and icons.general("refresh") or icons.general("success")),
		}
		if is_own_comment(comment, current_user) then
			table.insert(actions, string.format("%s (e)", icons.general("edit")))
			table.insert(actions, string.format("%s (d)", icons.general("delete")))
		end

		return {
			icon = "",
			author = string.format("%s %s", checkbox, heading),
			additional = string.format("by @%s   %s", creator, table.concat(actions, "  ")),
			right_text = utils.relative_time(comment.created_on),
			content = nil,
			footer_items = {},
			children = children,
			line_map = { comment = comment, entity_kind = "task" },
			meta = {
				comment = comment,
				author_hl_name = creator,
				is_task = true,
				is_resolved = is_resolved,
			},
		}
	end

	local text = is_deleted and "(deleted comment)" or utils.strip_markup(comment.content_raw or "")
	if text == "" then
		text = "(empty comment)"
	end

	local author = author_name(comment.author)
	local footer_items = { string.format("%s (c)", icons.general("reply")) }
	if not is_deleted and is_own_comment(comment, current_user) then
		table.insert(footer_items, string.format("%s (e)", icons.general("edit")))
		table.insert(footer_items, string.format("%s (d)", icons.general("delete")))
	end

	local marker, marker_hl
	if is_root then
		marker, marker_hl = root_marker(comment)
	end

	return {
		icon = icons.general("user"),
		author = tostring(author),
		additional = utils.relative_time(comment.created_on),
		right_text = marker,
		content = text,
		children = children,
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

---@param helper { author_hl: fun(name: string): string }
---@param padding_x integer
---@return AtlasThreadV2RenderOpts
function M.threads_opts(helper, padding_x)
	return {
		padding_x = padding_x,
		separator = "─",
		additional_hl = function(item)
			local meta = item and item.meta or {}
			if meta.is_task == true then
				local name = tostring(meta.author_hl_name or "")
				if name ~= "" then
					return helper.author_hl(name)
				end
			end
			return "AtlasTextMuted"
		end,
		author_hl = function(item, author)
			local meta = item and item.meta or nil
			if meta and meta.is_task == true then
				return nil
			end
			local author_hl_name = meta and meta.author_hl_name or author
			return helper.author_hl(author_hl_name)
		end,
		icon_hl_fn = function(item)
			local meta = item and item.meta or nil
			local author_hl_name = meta and meta.author_hl_name or tostring(item.author or "")
			return helper.author_hl(author_hl_name)
		end,
		content_hl = function(item, row)
			local meta = item and item.meta or {}
			if meta.is_task == true then
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

return M
