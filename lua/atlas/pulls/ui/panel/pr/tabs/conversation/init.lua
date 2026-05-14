---@class ConversationTab : PullsPanelTabModule
local M = {}

local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.conversation.renderer")

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

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	cancel_all()
	state.reset()
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end

	local pr_id = tostring(pr.id or "")

	if type(provider.fetch_conversation) == "function" then
		state.comments = "loading"
		state.activity = "loading"
		footer.notify("loading", string.format("Loading conversation for #%s...", pr_id))
		track(provider.fetch_conversation(pr, opts, function(result, err)
			if err then
				state.comments = err
				state.activity = err
				footer.notify("error", string.format("Failed to load conversation for #%s", pr_id))
			else
				result = type(result) == "table" and result or {}
				state.comments = type(result.comments) == "table" and result.comments or {}
				state.activity = type(result.events) == "table" and result.events or {}
				state.reaction_options = type(result.reaction_options) == "table" and result.reaction_options or {}
				footer.notify("success", string.format("Conversation loaded for #%s", pr_id), 1200)
			end
			refresh()
		end))
	end
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "comment" or entry.kind == "activity"
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	require("atlas.pulls.ui.panel.pr.tabs.conversation.keymaps").setup(buf, refresh)
end

function M.deactivate(buf)
	if buf ~= nil then
		require("atlas.pulls.ui.panel.pr.tabs.conversation.keymaps").teardown(buf)
	end
	cancel_all()
end

return M
