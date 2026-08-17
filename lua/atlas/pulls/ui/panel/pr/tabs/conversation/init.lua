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

function M.reset()
	state.reset()
end

---@param pr PullRequest
---@param _repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, _repo, refresh, opts)
	local request_generation = state.activate(pr)
	opts = opts or {}

	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.comments = {}
		state.tasks = {}
		state.activity = {}
		refresh()
		return
	end

	local id = tostring(pr.id or "")
	state.comments = "loading"
	state.tasks = "loading"
	state.activity = "loading"
	statusline.notify("loading", string.format("Loading conversation for #%s...", id))

	state.requests.run(function(done)
		return comments.fetch_conversation(pr, opts, done)
	end, function(result, err)
		if not state.is_current(request_generation, pr) then
			return
		end
		if err then
			state.comments = {}
			state.tasks = {}
			state.activity = {}
			state.error = tostring(err)
			statusline.notify("error", string.format("Failed to load conversation for #%s", id))
		else
			result = type(result) == "table" and result or {}
			state.comments = {}
			for _, comment in ipairs(type(result.comments) == "table" and result.comments or {}) do
				if comment.state ~= "DELETED" then
					table.insert(state.comments, comment)
				end
			end
			state.tasks = type(result.tasks) == "table" and result.tasks or {}
			state.activity = type(result.events) == "table" and result.events or {}
			state.error = nil
			statusline.notify("success", string.format("Conversation loaded for #%s", id), 1200)
		end
		refresh()
	end)
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry)
	return entry.entity_kind == "comment"
		or entry.entity_kind == "task"
		or entry.activity_entry ~= nil
		or entry.kind == "activity_gap"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	if not entry or (entry.entity_kind ~= "comment" and entry.entity_kind ~= "task") or not entry.comment then
		return
	end
	local url = tostring(entry.comment.html_url or entry.comment.url or "")
	if url ~= "" then
		vim.ui.open(url)
		return true
	end
end

---@return boolean
function M.is_loading()
	return state.any_loading()
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
	state.deactivate()
end

return M
