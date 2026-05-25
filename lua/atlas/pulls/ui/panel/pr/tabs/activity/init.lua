---@class PullsActivityTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local activity_component = require("atlas.pulls.ui.panel.pr.tabs.components.activity")
local state = require("atlas.pulls.ui.panel.pr.tabs.activity.state")

local PADDING_X = 1

---@type { cancel: fun() }[]
local in_flight = {}

---@return PullsProvider|nil
local function get_provider()
	local pulls_state = require("atlas.pulls.state")
	return pulls_state.provider
end

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

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts) ---@diagnostic disable-line: unused-local
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end

	local force_refresh = opts.force_refresh == true
	local should_fetch = force_refresh
		or state.activity == nil
		or state.activity == "loading"
		or type(state.activity) == "string"

	if should_fetch then
		cancel_all()
		state.reset()
	end

	local pr_id = tostring(pr.id or "")
	if should_fetch and type(provider.fetch_activity) == "function" then
		state.activity = "loading"
		footer.notify("loading", string.format("Loading activity for #%s...", pr_id))
		track(provider.fetch_activity(pr, opts, function(entries, err)
			if err then
				state.activity = err
				footer.notify("error", string.format("Failed to load activity for #%s", pr_id))
			else
				state.activity = entries or {}
				footer.notify("success", string.format("Activity loaded for #%s", pr_id), 1200)
			end
			refresh()
		end))
	end
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width) ---@diagnostic disable-line: unused-local
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
		utils.push(lines, spans, tostring(state.activity), "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local entries = state.activity
	---@cast entries PullsActivityEntry[]
	if #entries == 0 then
		utils.push(lines, spans, "No activity yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local item_lines, item_spans, item_map = activity_component.render(entries, width, { padding_x = PADDING_X })

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
function M.is_selectable_line(_lnum, entry) ---@diagnostic disable-line: unused-local
	local k = entry.kind
	return k == "header" or k == "content"
end

function M.deactivate()
	cancel_all()
end

return M
