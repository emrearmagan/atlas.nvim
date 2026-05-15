---@class IssuesActivityTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.issues.ui.panel.issue.tabs.activity.state")

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

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@param entries IssueActivityEntry[]|nil
---@return AtlasThreadV2Item[]
local function to_thread_items(entries)
	local out = {}
	for _, entry in ipairs(entries or {}) do
		local author = entry.actor and entry.actor.display_name or "Unknown"
		local timestamp = utils.relative_time_text(entry.date)
		table.insert(out, {
			icon = icons.general("user"),
			author = author,
			right_text = timestamp,
			additional = entry.label,
			content = entry.body,
			line_map = { kind = "history", activity_entry = entry },
		})
	end
	return out
end

---@param item AtlasThreadV2Item
---@param row string
---@param row_index integer
---@return table[]|nil
local function content_hl(item, row, row_index)
	local entry = item.line_map and item.line_map.activity_entry
	if not entry or type(entry.body_hl) ~= "function" then
		return nil
	end
	return entry.body_hl(row, row_index)
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}
	local provider = get_provider()
	if not provider or not provider.fetch_activity then
		return
	end

	local force_refresh = opts.force_refresh == true
	if not force_refresh and state.entries ~= nil then
		return
	end

	cancel_all()
	state.is_loading = true
	state.issue = issue

	local issue_key = tostring(issue.key or "")
	footer.notify("loading", string.format("Loading history for %s...", issue_key))

	track(provider.fetch_activity(issue, { force_load = force_refresh }, function(entries, err)
		state.is_loading = false

		if err then
			state.entries = {}
			footer.notify("error", string.format("Failed to load history for %s", issue_key))
		else
			state.entries = entries or {}
			footer.notify("success", string.format("History loaded for %s (%d)", issue_key, #state.entries), 1200)
		end

		refresh()
	end))
end

---@param issue Issue
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, width)
	local lines = {}
	local spans = {}

	if state.is_loading then
		utils.push(lines, spans, spinner.with_text("Loading history..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	if not state.entries or #state.entries == 0 then
		utils.push(lines, spans, "No history.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	local thread_items = to_thread_items(state.entries)

	local t_lines, t_spans, t_line_map = threads.render(thread_items, width, {
		padding_x = PADDING_X,
		mode = "tree",
		author_hl = function(_, author)
			return highlights.dynamic_for(author)
		end,
		icon_hl_fn = function(item)
			local author = tostring(item.author or "")
			return highlights.dynamic_for(author)
		end,
		additional_hl = function()
			return "AtlasTextMuted"
		end,
		content_hl = content_hl,
	})

	utils.append_block(lines, spans, { lines = t_lines, highlights = t_spans })

	local line_map = {}
	for lnum, entry in pairs(t_line_map or {}) do
		line_map[#lines - #t_lines + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "history"
end

function M.activate() end

function M.deactivate()
	cancel_all()
	if state.is_loading then
		state.is_loading = false
		footer.notify("info", "", 0)
	end
end

return M
