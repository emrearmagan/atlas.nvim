local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local threads = require("atlas.ui.components.threadsv2")
local helper = require("atlas.issues.ui.main.helper")

local COLLAPSE_KEEP = 2
local COLLAPSE_THRESHOLD = 4

---@param actor IssueUser|nil
---@return string
local function actor_name(actor)
	if type(actor) ~= "table" then
		return "Unknown"
	end
	if actor.display_name and actor.display_name ~= "" then
		return actor.display_name
	end
	if actor.account_id and actor.account_id ~= "" then
		return actor.account_id
	end
	return "Unknown"
end

local EVENT_ICON = {
	labeled = icons.pulls("activity"),
	unlabeled = icons.pulls("activity"),
	assigned = icons.general("user"),
	unassigned = icons.general("user"),
	milestoned = icons.pulls("activity"),
	demilestoned = icons.pulls("activity"),
	renamed = icons.general("edit"),
	closed = icons.pulls_status("successful"),
	reopened = icons.issues("issue"),
	locked = icons.pulls_status("stopped"),
	unlocked = icons.pulls_status("stopped"),
	pinned = icons.pulls("activity"),
	unpinned = icons.pulls("activity"),
	transferred = icons.pulls("activity"),
	marked_as_duplicate = icons.pulls("activity"),
	["cross-referenced"] = icons.pulls("activity"),
	referenced = icons.pulls("activity"),
}

---@param entry IssueActivityEntry
---@return { icon: string, additional: string|nil, content: string|nil }
function M.classify(entry)
	local raw = tostring(entry.label or "")
	return {
		icon = EVENT_ICON[entry.kind] or icons.pulls("activity"),
		additional = raw ~= "" and raw or entry.kind,
		content = nil,
	}
end

---@param entries IssueActivityEntry[]
---@param run_id string|nil
---@return AtlasThreadV2Item[]
local function to_thread_items(entries, run_id)
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
				run_id = run_id,
			},
		}
	end
	return items
end

---@param _item AtlasThreadV2Item
---@param _text string
---@return string|nil
local function additional_hl(_item, _text)
	return "AtlasTextMuted"
end

---@param item AtlasThreadV2Item
local function icon_hl_fn(item)
	local author = vim.trim(tostring(item.author or "")):lower()
	return highlights.dynamic_for(author) or "AtlasTextMuted"
end

---@param item AtlasThreadV2Item
---@param _author string
local function author_hl(item, _author)
	return helper.person_hl(item.author)
end

---@param entries IssueActivityEntry[]
---@param width integer
---@param opts { padding_x: integer|nil, content_max_lines: integer|nil, squash: boolean|nil, run_id: string|nil }|nil
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
		append(threads.render(to_thread_items({ entry }, opts.run_id), width, {
			padding_x = padding_x,
			content_max_lines = content_max_lines,
			additional_hl = additional_hl,
			icon_hl_fn = icon_hl_fn,
			author_hl = author_hl,
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
			{ { line = 0, start_col = padding_x, end_col = padding_x + #text, hl_group = "AtlasTextMuted" } },
			opts.run_id and { [1] = { kind = "activity_gap", run_id = opts.run_id } } or nil
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
