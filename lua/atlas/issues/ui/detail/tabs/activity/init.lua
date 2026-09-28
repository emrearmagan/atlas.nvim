local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local activity = require("atlas.issues.ui.detail.components.activity")
local notify = require("atlas.core.notify")
local detail = require("atlas.issues.ui.detail.state")
local request_scope = require("atlas.core.requests")

local PADDING_X = 1

---@class IssuesActivityTabState
---@field entries IssueActivityEntry[]|nil
---@field error string|nil
---@field loading boolean
---@field requests AtlasRequestScope
local state = {
	entries = nil,
	error = nil,
	loading = false,
	requests = request_scope.new(),
}

function M.reset()
	state.requests.cancel()
	state.requests = request_scope.new()
	state.entries = nil
	state.error = nil
	state.loading = false
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_activity then
		return
	end

	local force_refresh = opts.force_refresh == true
	if not force_refresh and state.entries ~= nil then
		return
	end

	M.reset()
	state.loading = true

	local issue_key = tostring(issue.key or "")
	notify.loading(string.format("Loading history for %s...", issue_key))
	state.requests.run(function(done)
		return comments.fetch_activity(issue, { force_refresh = force_refresh }, done)
	end, function(entries, err)
		state.loading = false
		if err then
			state.error = tostring(err)
			notify.error(string.format("Failed to load history for %s", issue_key))
		else
			state.entries = entries or {}
			state.error = nil
			notify.success(string.format("History loaded for %s (%d)", issue_key, #state.entries), {
				timeout = 1200,
			})
		end
		refresh()
	end)
end

---@param _issue Issue
---@param _details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_issue, _details, width)
	local lines = {}
	local spans = {}

	if state.loading then
		utils.push(lines, spans, spinner.with_text("Loading history..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if state.error then
		utils.push(lines, spans, state.error, "AtlasLogError", PADDING_X)
		return lines, spans, {}
	end
	if not state.entries or #state.entries == 0 then
		utils.push(lines, spans, "No history.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	return activity.render(state.entries, width, {
		padding_x = PADDING_X,
		content_max_lines = 0,
	})
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.activity_entry ~= nil
end

---@return boolean
function M.is_loading()
	return state.loading
end

function M.deactivate()
	state.requests.cancel()
	state.requests = request_scope.new()
	if state.loading then
		state.loading = false
		notify.clear()
	end
end

return M
