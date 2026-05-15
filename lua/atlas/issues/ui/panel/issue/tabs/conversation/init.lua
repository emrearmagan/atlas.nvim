---@class IssuesConversationTab : IssuesPanelTabModule
local M = {}

local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
local renderer = require("atlas.issues.ui.panel.issue.tabs.conversation.renderer")
local keymaps = require("atlas.issues.ui.panel.issue.tabs.conversation.keymaps")
local footer = require("atlas.ui.components.footer")

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, h in ipairs(in_flight) do
		if h and h.cancel then
			pcall(h.cancel)
		end
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	cancel_all()
	state.reset()
	opts = opts or {}

	local provider = get_provider()
	if not provider or type(provider.fetch_conversation) ~= "function" then
		state.comments = {}
		state.activity = {}
		refresh()
		return
	end

	local key = tostring(issue.key or "")
	state.comments = "loading"
	state.activity = "loading"
	footer.notify("loading", string.format("Loading conversation for %s...", key))

	track(provider.fetch_conversation(issue, opts, function(result, err)
		if err then
			state.comments = err
			state.activity = err
			footer.notify("error", string.format("Failed to load conversation for %s", key))
		else
			result = type(result) == "table" and result or {}
			state.comments = type(result.comments) == "table" and result.comments or {}
			state.activity = type(result.events) == "table" and result.events or {}
			state.reaction_options = type(result.reaction_options) == "table" and result.reaction_options or {}
			footer.notify("success", string.format("Conversation loaded for %s", key), 1200)
		end
		refresh()
	end))
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry) ---@diagnostic disable-line: unused-local
	return entry.kind == "comment" or entry.activity_entry ~= nil or entry.kind == "activity_gap"
end

---@param _issue Issue
---@param entry table
function M.on_enter(_issue, entry) ---@diagnostic disable-line: unused-local
	if entry and entry.kind == "comment" and entry.comment then
		local url = tostring(entry.comment.url or "")
		if url ~= "" then
			vim.ui.open(url)
			return true
		end
	end
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	cancel_all()
end

return M
