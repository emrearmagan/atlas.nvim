---@class ConversationTab : PullsPanelTabModule
local M = {}

local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")
local renderer = require("atlas.pulls.ui.panel.pr.tabs.conversation.renderer")
local keymaps = require("atlas.pulls.ui.panel.pr.tabs.conversation.keymaps")
local statusline = require("atlas.ui.statusline")

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
function M.on_select(pr, _repo, refresh, opts)
	cancel_all()
	state.reset()
	opts = opts or {}

	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.comments = {}
		state.activity = {}
		refresh()
		return
	end

	local id = tostring(pr.id or "")
	state.comments = "loading"
	state.activity = "loading"
	statusline.notify("loading", string.format("Loading conversation for #%s...", id))

	track(comments.fetch_conversation(pr, opts, function(result, err)
		if err then
			state.comments = err
			state.activity = err
			statusline.notify("error", string.format("Failed to load conversation for #%s", id))
		else
			result = type(result) == "table" and result or {}
			state.comments = type(result.comments) == "table" and result.comments or {}
			state.activity = type(result.events) == "table" and result.events or {}
			statusline.notify("success", string.format("Conversation loaded for #%s", id), 1200)
		end
		refresh()
	end))
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry)
	return entry.entity_kind == "comment" or entry.activity_entry ~= nil or entry.kind == "activity_gap"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
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
