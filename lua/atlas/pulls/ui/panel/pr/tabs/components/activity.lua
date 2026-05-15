local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local threads = require("atlas.ui.components.threadsv2")

local COLLAPSE_KEEP = 2
local COLLAPSE_THRESHOLD = 5

---@param actor {nickname:string?, name:string?}|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.nickname and actor.nickname ~= "" then
		return actor.nickname
	end
	if actor.name and actor.name ~= "" then
		return actor.name
	end
	return "Unknown"
end

---@param entry PullsActivityEntry
---@return { icon: string, icon_hl: string, additional: string|nil, content: string|nil }
function M.classify(entry)
	local kind = entry.kind
	local entry_icon = icons.general("user")
	local icon_hl
	local additional ---@type string|nil
	local content ---@type string|nil

	if kind == "approval" then
		additional = "approved"
		entry_icon = icons.pulls_status("successful")
		icon_hl = "AtlasTextPositive"
		local raw = tostring(entry.content_raw or "")
		if raw ~= "" then
			content = raw
		end
	elseif kind == "changes_requested" then
		additional = "requested changes"
		entry_icon = icons.pulls_status("inprogress")
		icon_hl = "AtlasTextWarning"
		local raw = tostring(entry.content_raw or "")
		if raw ~= "" then
			content = raw
		end
	elseif kind == "review" then
		additional = "left a review"
		entry_icon = icons.pulls("activity")
		local raw = tostring(entry.content_raw or "")
		if raw ~= "" then
			content = raw
		end
	elseif kind == "comment" then
		additional = "commented"
		local raw = utils.strip_markup(entry.content_raw or "")
		local first = raw:match("([^\n]+)") or raw
		content = first ~= "" and first or "(empty comment)"
		if entry.deleted == true then
			content = "(deleted comment)"
		end
	elseif kind == "update" then
		additional = type(entry.content_raw) == "string" and entry.content_raw ~= "" and entry.content_raw
			or "updated pull request"
		entry_icon = icons.pulls("activity")
	end

	return { icon = entry_icon, icon_hl = icon_hl, additional = additional, content = content }
end

---@param entries PullsActivityEntry[]
---@return AtlasThreadV2Item[]
local function to_thread_items(entries)
	local items = {}
	for _, e in ipairs(entries) do
		local classified = M.classify(e)
		items[#items + 1] = {
			icon = classified.icon,
			author = actor_name(e.actor),
			right_text = utils.relative_time(e.date),
			additional = classified.additional,
			content = classified.content,
			line_map = {
				kind = "activity",
				activity_entry = e,
				activity_actor = e.actor,
			},
		}
	end
	return items
end

---@param item AtlasThreadV2Item
---@param _text string
---@return string|nil
local function additional_hl(item, _text)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return "AtlasTextMuted"
	end
	if entry.kind == "approval" then
		return "AtlasTextPositive"
	end
	if entry.kind == "changes_requested" then
		return "AtlasTextWarning"
	end
	return "AtlasTextMuted"
end

---@param item AtlasThreadV2Item
---@param row string
---@param _row_index integer
---@return table[]|nil
local function content_hl(item, row, _row_index)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return nil
	end

	if entry.kind == "comment" and entry.deleted == true then
		return {
			{ start_col = 0, end_col = #row, hl_group = "AtlasTextMutedStrikethrough" },
		}
	end

	if entry.kind == "update" then
		return {
			{ start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" },
		}
	end

	return nil
end

---@param item AtlasThreadV2Item
local function icon_hl_fn(item)
	local entry = item.line_map and item.line_map.activity_entry
	if entry and entry.kind == "approval" then
		return "AtlasTextPositive"
	end
	if entry and entry.kind == "changes_requested" then
		return "AtlasTextWarning"
	end
	local author = vim.trim(tostring(item.author or "")):lower()
	return highlights.dynamic_for(author) or "AtlasTextMuted"
end

---Render a list of activities.
---@param entries PullsActivityEntry[]
---@param width integer
---@param opts { padding_x: integer|nil, content_max_lines: integer|nil, squash: boolean|nil }|nil
---@return string[] lines, table[] spans, table<integer, table>|nil line_map
function M.render(entries, width, opts)
	opts = opts or {}
	local padding_x = opts.padding_x or 1
	local content_max_lines = opts.content_max_lines or 3

	local lines, spans, line_map = {}, {}, {}

	local function append(sub_lines, sub_spans, sub_map)
		local base = #lines
		for _, l in ipairs(sub_lines) do
			table.insert(lines, l)
		end
		for _, s in ipairs(sub_spans) do
			s.line = s.line + base
			table.insert(spans, s)
		end
		for lnum, data in pairs(sub_map or {}) do
			line_map[base + lnum] = data
		end
	end

	local function separator()
		if #lines == 0 then
			return
		end
		local line = string.rep(" ", padding_x) .. "│"
		append(
			{ line },
			{ { line = 0, start_col = padding_x, end_col = padding_x + #"│", hl_group = "AtlasBorder" } }
		)
	end

	local function render_entry(entry)
		separator()
		append(threads.render(to_thread_items({ entry }), width, {
			padding_x = padding_x,
			content_max_lines = content_max_lines,
			additional_hl = additional_hl,
			content_hl = content_hl,
			icon_hl_fn = icon_hl_fn,
		}))
	end

	local function render_gap(count)
		separator()
		local text = string.format(
			"%s  ... %d more %s",
			icons.general("activity_more"),
			count,
			count == 1 and "activity" or "activities"
		)
		local line = string.rep(" ", padding_x) .. text
		append(
			{ line },
			{ { line = 0, start_col = padding_x, end_col = padding_x + #text, hl_group = "AtlasTextMuted" } }
		)
	end

	if opts.squash and #entries > COLLAPSE_THRESHOLD then
		for i = 1, COLLAPSE_KEEP do
			render_entry(entries[i])
		end
		render_gap(#entries - (COLLAPSE_KEEP * 2))
		for i = #entries - COLLAPSE_KEEP + 1, #entries do
			render_entry(entries[i])
		end
	else
		for _, entry in ipairs(entries) do
			render_entry(entry)
		end
	end

	return lines, spans, line_map
end

return M
