---@class GHIssuesActivityTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.issues.providers.github.ui.activity.state")

local PADDING_X = 1

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

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
---@param entry GHIssueTimelineEntry
---@return string additional, string|nil content
local function activity_text(entry)
	local kind = tostring(entry.event or "")
	if kind == "commented" then
		return "commented", nil
	elseif kind == "created" then
		return "created issue", nil
	elseif kind == "labeled" then
		return "added label", tostring(entry.label_name or "")
	elseif kind == "unlabeled" then
		return "removed label", tostring(entry.label_name or "")
	elseif kind == "assigned" then
		return "assigned", tostring(entry.assignee_login or "")
	elseif kind == "unassigned" then
		return "unassigned", tostring(entry.assignee_login or "")
	elseif kind == "milestoned" then
		return "added milestone", tostring(entry.milestone_title or "")
	elseif kind == "demilestoned" then
		return "removed milestone", tostring(entry.milestone_title or "")
	elseif kind == "renamed" then
		return "renamed", string.format("%s → %s", tostring(entry.rename_from or ""), tostring(entry.rename_to or ""))
	elseif kind == "closed" then
		return "closed", entry.commit_id and string.format("commit %s", entry.commit_id) or nil
	elseif kind == "reopened" then
		return "reopened", nil
	elseif kind == "locked" then
		return "locked conversation", nil
	elseif kind == "unlocked" then
		return "unlocked conversation", nil
	elseif kind == "pinned" then
		return "pinned this issue", nil
	elseif kind == "unpinned" then
		return "unpinned this issue", nil
	elseif kind == "transferred" then
		return "transferred this issue", nil
	elseif kind == "marked_as_duplicate" then
		return "marked as duplicate", nil
	elseif kind == "cross-referenced" then
		return "referenced this from", tostring(entry.source_title or entry.source_url or "")
	elseif kind == "referenced" then
		return "referenced", entry.commit_id and string.format("commit %s", entry.commit_id) or nil
	end
	return kind ~= "" and kind or "updated issue", nil
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return "AtlasChipActive"
	end
	local name = "AtlasGHIssueLabel_" .. clean
	vim.api.nvim_set_hl(0, name, { fg = "#000000", bg = "#" .. clean, bold = true })
	return name
end

local EVENT_ICON = {
	commented = icons.general("comment"),
	created = icons.general("created"),
	labeled = icons.pulls("activity"),
	unlabeled = icons.pulls("activity"),
	assigned = icons.general("user"),
	unassigned = icons.general("user"),
	milestoned = icons.pulls("activity"),
	demilestoned = icons.pulls("activity"),
	renamed = icons.general("edit"),
	closed = icons.pulls_status("successful"),
	reopened = icons.pulls("issue"),
	locked = icons.pulls_status("stopped"),
	unlocked = icons.pulls_status("stopped"),
	pinned = icons.pulls("activity"),
	unpinned = icons.pulls("activity"),
	transferred = icons.pulls("activity"),
	marked_as_duplicate = icons.pulls("activity"),
	["cross-referenced"] = icons.pulls("activity"),
	referenced = icons.pulls("activity"),
}

---@param entries GHIssueTimelineEntry[]
---@return AtlasThreadV2Item[]
local function to_thread_items(entries)
	local items = {}
	for _, entry in ipairs(entries or {}) do
		local kind = tostring(entry.event or "")
		local additional, content = activity_text(entry)
		items[#items + 1] = {
			icon = EVENT_ICON[kind] or icons.pulls("activity"),
			author = actor_name(entry.actor),
			right_text = utils.relative_time(entry.date),
			additional = additional,
			content = content ~= "" and content or nil,
			line_map = {
				activity_entry = entry,
				activity_actor = entry.actor,
			},
		}
	end
	return items
end

---@param item AtlasThreadV2Item
---@return string|nil
local function additional_hl(item)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return "AtlasTextMuted"
	end
	return "AtlasTextMuted"
end

---@param item AtlasThreadV2Item
---@param row string
---@return table[]|nil
local function content_hl(item, row)
	local entry = item.line_map and item.line_map.activity_entry
	if entry == nil then
		return nil
	end

	local event = tostring(entry.event or "")
	local hl = nil
	if event == "labeled" or event == "unlabeled" then
		hl = label_hl(entry.label_color)
	elseif event == "assigned" or event == "unassigned" then
		hl = highlights.dynamic_for(entry.assignee_login)
	elseif event == "milestoned" or event == "demilestoned" then
		hl = highlights.dynamic_for(entry.milestone_title)
	elseif event == "closed" then
		hl = "AtlasGHIssueClosed"
	elseif event == "reopened" then
		hl = "AtlasGHIssueOpen"
	end

	return {
		{ start_col = 0, end_col = #row, hl_group = hl or "AtlasTextMuted" },
	}
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}
	local force_refresh = opts.force_refresh == true
	local same_issue = state.issue ~= nil and tostring(state.issue.key or "") == tostring(issue.key or "")
	local should_fetch = force_refresh or not same_issue or state.activity == nil or state.activity == "loading" or type(state.activity) == "string"

	if not should_fetch then
		return
	end

	cancel_all()
	state.reset()
	state.issue = issue
	state.activity = "loading"

	local key = tostring(issue.key or "")
	footer.notify("loading", string.format("Loading activity for %s...", key))

	local timeline_api = require("atlas.issues.providers.github.api.timeline")
	track(timeline_api.list(key, function(entries, err)
		if err then
			state.activity = err
			footer.notify("error", string.format("Failed to load activity for %s", key), 1600)
		else
			state.activity = entries or {}
			table.sort(state.activity, function(a, b)
				return tostring(a.date or "") > tostring(b.date or "")
			end)
			footer.notify("success", string.format("Activity loaded for %s", key), 1200)
		end
		refresh()
	end, { force_load = force_refresh }))
end

---@param _issue Issue
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_issue, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.activity == nil then
		return lines, spans, line_map
	end

	if state.activity == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading activity..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(state.activity) == "string" then
		utils.push(lines, spans, state.activity, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local entries = state.activity
	if #entries == 0 then
		utils.push(lines, spans, "No activity yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local items = to_thread_items(entries)
	local item_lines, item_spans, item_map = threads.render(items, width, {
		padding_x = PADDING_X,
		content_max_lines = 3,
		additional_hl = additional_hl,
		content_hl = content_hl,
		icon_hl_fn = function(item)
			return "AtlasTextMuted"
		end,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = item_lines, highlights = item_spans })
	for lnum, entry in pairs(item_map or {}) do
		line_map[offset + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	local kind = entry and entry.kind
	return kind == "header" or kind == "content"
end

function M.deactivate()
	cancel_all()
end

return M
