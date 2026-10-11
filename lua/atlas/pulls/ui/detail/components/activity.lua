local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local activity = require("atlas.ui.components.activity")
local presentation = require("atlas.pulls.ui.presentation")

local EVENT = {
	approval = icons.get("successful", "status"),
	unapproval = icons.get("inprogress", "status"),
	changes_requested = icons.get("inprogress", "status"),
	review = icons.get("activity"),
	review_dismissed = icons.get("stopped", "status"),
	comment = icons.get("user"),
	comment_deleted = icons.get("delete"),
	closed = icons.get("declined_pr"),
	merged = icons.get("merged_pr"),
	reopened = icons.get("pr"),
	committed = icons.get("commit"),
	force_pushed = icons.get("edit"),
	labeled = icons.get("tag"),
	unlabeled = icons.get("tag"),
	assigned = icons.get("user"),
	unassigned = icons.get("user"),
	review_requested = icons.get("user"),
	renamed = icons.get("edit"),
	ready_for_review = icons.get("pr"),
	convert_to_draft = icons.get("draft_pr"),
	update = icons.get("activity"),
}

---@param entry PullsActivityEntry
---@return { icon: string, icon_hl: string|nil, additional: string, additional_hl: string, content: string|nil }
local function classify(entry)
	local icon = EVENT[entry.kind] or icons.get("activity")
	local icon_hl = "AtlasTextMuted"
	local additional_hl = "AtlasTextMuted"
	if entry.kind == "approval" then
		icon_hl = "AtlasTextPositive"
		additional_hl = "AtlasTextPositive"
	elseif entry.kind == "changes_requested" then
		icon_hl = "AtlasTextWarning"
		additional_hl = "AtlasTextWarning"
	elseif entry.kind == "unapproval" then
		additional_hl = "AtlasTextWarning"
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
		additional_hl = additional_hl,
		content = body,
	}
end

---@param entries PullsActivityEntry[]
---@param run_id string|nil
---@return AtlasThreadItem[]
local function to_thread_items(entries, run_id)
	local items = {}
	for _, e in ipairs(entries) do
		local classified = classify(e)

		items[#items + 1] = {
			icon = classified.icon,
			icon_hl = classified.icon_hl,
			author = presentation.author_name(e.actor),
			right_text = { { utils.relative_time(e.date), "AtlasTextMuted" } },
			additional = { { classified.additional, classified.additional_hl } },
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
			content_hl = content_hl,
		})
	)
end

return M
