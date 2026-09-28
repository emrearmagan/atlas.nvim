local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local activity = require("atlas.ui.components.activity")

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
---@return AtlasThreadItem[]
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

---@param item AtlasThreadItem
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

---@param item AtlasThreadItem
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
---@param opts? { padding_x?: integer, content_max_lines?: integer, squash?: boolean, run_id?: string, has_next?: boolean }
---@return string[] lines, table[] spans, table<integer, table>|nil line_map
function M.render(entries, width, opts)
	opts = opts or {}
	return activity.render(
		to_thread_items(entries, opts.run_id),
		width,
		vim.tbl_extend("force", opts, {
			additional_hl = additional_hl,
			content_hl = content_hl,
		})
	)
end

return M
