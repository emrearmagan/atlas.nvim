---@class IssuesConversationTab : IssuesPanelTabModule
local M = {}

local state = require("atlas.issues.ui.panel.issue.tabs.conversation.state")
local renderer = require("atlas.issues.ui.panel.issue.tabs.conversation.renderer")
local keymaps = require("atlas.issues.ui.panel.issue.tabs.conversation.keymaps")
local notify = require("atlas.core.notify")

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

function M.reset()
	state.reset()
	notify.clear()
end

---@param issue IssueDetails
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	local generation = state.activate(issue)
	opts = opts or {}

	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.items = {}
		refresh()
		return
	end

	local key = tostring(issue.key or "")
	state.items = "loading"
	notify.loading(string.format("Loading conversation for %s...", key))

	state.requests.run(function(done)
		return comments.fetch_conversation(issue, opts, done)
	end, function(result, err)
		if not state.is_current(generation, issue) then
			return
		end
		state.items = {}
		if result then
			for _, item in ipairs(result) do
				if item.kind ~= "comment" or item.entity.deleted ~= true then
					table.insert(state.items, item)
				end
			end
		end

		state.error = nil
		if err then
			if not result then
				state.error = tostring(err)
			end
			local message = result and "Conversation for %s partially failed: %s"
				or "Failed to load conversation for %s: %s"
			notify.error(string.format(message, key, tostring(err)))
		else
			notify.success(string.format("Conversation loaded for %s", key), { timeout = 1200 })
		end
		refresh()
	end)
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry) ---@diagnostic disable-line: unused-local
	return entry.conversation_item ~= nil or entry.kind == "activity_gap"
end

---@param _issue Issue
---@param entry table
function M.on_enter(_issue, entry)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	if item.kind ~= "description" and item.kind ~= "comment" then
		return
	end
	local url = tostring(item.entity.url or "")
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
	notify.clear()
end

return M
