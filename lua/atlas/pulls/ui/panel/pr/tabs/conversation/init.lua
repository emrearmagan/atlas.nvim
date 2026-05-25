---@class ConversationTab : PullsPanelTabModule
local M = {}

local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.conversation.renderer")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.conversation.keymaps")
local footer = require("atlas.ui.components.footer")

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
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

---@param pr PullRequest
---@param _repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, _repo, refresh, opts) ---@diagnostic disable-line: unused-local
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

	local id = tostring(pr.id or "")
	state.comments = "loading"
	state.activity = "loading"
	footer.notify("loading", string.format("Loading conversation for #%s...", id))

	track(provider.fetch_conversation(pr, opts, function(result, err)
		if err then
			state.comments = err
			state.activity = err
			footer.notify("error", string.format("Failed to load conversation for #%s", id))
		else
			result = type(result) == "table" and result or {}
			state.comments = type(result.comments) == "table" and result.comments or {}
			state.activity = type(result.events) == "table" and result.events or {}
			state.reaction_options = type(result.reaction_options) == "table" and result.reaction_options or {}
			footer.notify("success", string.format("Conversation loaded for #%s", id), 1200)
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

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry) ---@diagnostic disable-line: unused-local
	if not entry or entry.kind ~= "comment" or not entry.comment then
		return
	end
	local url = tostring(entry.comment.html_url or "")
	if url ~= "" then
		vim.ui.open(url)
		return true
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
