local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local threads = require("atlas.ui.components.threadsv2")

local COLLAPSE_KEEP = 3
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

local EVENT = {
	approval = icons.pulls_status("successful"),
	unapproval = icons.pulls_status("inprogress"),
	changes_requested = icons.pulls_status("inprogress"),
	review = icons.pulls("activity"),
	review_dismissed = icons.pulls_status("stopped"),
	comment = icons.general("user"),
	comment_deleted = icons.general("delete"),
	closed = icons.pulls("declined_pr"),
	merged = icons.pulls("merged_pr"),
	reopened = icons.pulls("pr"),
	committed = icons.pulls("commit"),
	force_pushed = icons.general("edit"),
	labeled = icons.pulls("tag"),
	unlabeled = icons.pulls("tag"),
	assigned = icons.general("user"),
	unassigned = icons.general("user"),
	review_requested = icons.general("user"),
	renamed = icons.general("edit"),
	ready_for_review = icons.pulls("pr"),
	convert_to_draft = icons.pulls("activity"),
	update = icons.pulls("activity"),
}

---@param entry PullsActivityEntry
---@return { icon: string, icon_hl: string|nil, additional: string|nil, content: string|nil }
function M.classify(entry)
	local icon = EVENT[entry.kind] or icons.pulls("activity")
	local icon_hl = "AtlasTextMuted"
	if entry.kind == "approval" then
		icon_hl = "AtlasTextPositive"
	elseif entry.kind == "changes_requested" then
		icon_hl = "AtlasTextWarning"
	end
	local label = tostring(entry.label or "")
	local body = entry.body
	if entry.kind == "comment" and entry.deleted == true then
		body = "(deleted comment)"
	end
	return {
		icon = icon,
		icon_hl = icon_hl,
		additional = label ~= "" and label or entry.kind,
		content = body,
	}
end

---@param entries PullsActivityEntry[]
---@param run_id string|nil
---@return AtlasThreadV2Item[]
local function to_thread_items(entries, run_id)
	local items = {}
	for _, e in ipairs(entries) do
		local classified = M.classify(e)
		items[#items + 1] = {
			icon = classified.icon,
			icon_hl = classified.icon_hl,
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
	if entry.kind == "unapproval" or entry.kind == "changes_requested" then
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

	return nil
end

---Render a list of activities.
---@param entries PullsActivityEntry[]
---@param width integer
---@param opts { padding_x: integer|nil, content_max_lines: integer|nil, squash: boolean|nil, run_id: string|nil, has_next: boolean|nil }|nil
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
			{ { line = 0, start_col = padding_x, end_col = padding_x + #"│", hl_group = "AtlasTextMuted" } }
		)
	end

	local function render_entry(entry, has_next)
		separator()
		append(threads.render(to_thread_items({ entry }, opts.run_id), width, {
			padding_x = padding_x,
			content_max_lines = content_max_lines,
			content_prefix = has_next and "│  " or "   ",
			additional_hl = additional_hl,
			content_hl = content_hl,
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
		render_gap(#entries - COLLAPSE_KEEP)
		for i = #entries - COLLAPSE_KEEP + 1, #entries do
			render_entry(entries[i], i < #entries or opts.has_next == true)
		end
	else
		for i, entry in ipairs(entries) do
			render_entry(entry, i < #entries or opts.has_next == true)
		end
	end

	return lines, spans, line_map
end

return M
