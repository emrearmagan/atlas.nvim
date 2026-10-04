local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local activity = require("atlas.ui.components.activity")
local helper = require("atlas.issues.ui.presentation")

---@param actor AtlasUser|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.name and actor.name ~= "" then
		return actor.name
	end
	if actor.username and actor.username ~= "" then
		return actor.username
	end
	if actor.id and actor.id ~= "" then
		return actor.id
	end
	return "Unknown"
end

local EVENT_ICON = {
	labeled = { icons.pulls("activity") },
	unlabeled = { icons.pulls("activity") },
	assigned = { icons.general("user") },
	unassigned = { icons.general("user") },
	milestoned = { icons.pulls("activity") },
	demilestoned = { icons.pulls("activity") },
	renamed = { icons.general("edit"), "AtlasTextMuted" },
	closed = { icons.pulls_status("successful") },
	reopened = { icons.issues("issue") },
	locked = { icons.pulls_status("stopped") },
	unlocked = { icons.pulls_status("stopped") },
	pinned = { icons.pulls("activity") },
	unpinned = { icons.pulls("activity") },
	transferred = { icons.pulls("activity") },
	marked_as_duplicate = { icons.pulls("activity") },
	["cross-referenced"] = { icons.pulls("activity") },
	referenced = { icons.pulls("activity") },
}

---@param entry IssueActivityEntry
---@return { icon: string, icon_hl: string, additional: string, content: string|nil }
function M.classify(entry)
	local raw = tostring(entry.label or "")
	local style = EVENT_ICON[entry.kind] or { icons.pulls("activity") }
	return {
		icon = style[1],
		icon_hl = style[2],
		additional = raw ~= "" and raw or entry.kind,
		content = entry.body,
	}
end

---@param entries IssueActivityEntry[]
---@param run_id string|nil
---@return AtlasThreadItem[]
local function to_thread_items(entries, run_id)
	local items = {}
	for _, e in ipairs(entries) do
		local classified = M.classify(e)
		local author = actor_name(e.actor)
		items[#items + 1] = {
			icon = classified.icon,
			icon_hl = classified.icon_hl,
			author = author,
			author_hl = helper.person_hl(author),
			right_text = { { utils.relative_time(e.date), "AtlasTextMuted" } },
			additional = { { classified.additional, "AtlasTextMuted" } },
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
---@param row_index integer
---@return table[]|nil
local function content_hl(item, row, row_index)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil or entry.body_hl == nil then
		return nil
	end
	return entry.body_hl(row, row_index)
end

---@param entries IssueActivityEntry[]
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
