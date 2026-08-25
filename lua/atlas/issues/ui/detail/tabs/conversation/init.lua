local M = {}

local renderer = require("atlas.issues.ui.detail.tabs.conversation.renderer")
local keymaps = require("atlas.issues.ui.detail.tabs.conversation.keymaps")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")
local notify = require("atlas.core.notify")

function M.reset()
	state.reset()
	notify.clear()
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	state.activate(issue)
	notify.clear()
	opts = opts or {}

	local provider = detail.provider
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
		if not state.is_current(issue) then
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

---@param issue Issue
---@param details IssueDetails|nil
---@param width integer
M.render = renderer.render

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.conversation_item ~= nil or entry.kind == "activity_gap"
end

---@param _issue Issue
---@param entry table
---@return boolean|nil
function M.on_enter(_issue, entry)
	local item = entry and entry.conversation_item or nil
	if not item or item.kind ~= "comment" then
		return
	end
	---@type IssueComment
	local comment = item.entity
	local url = tostring(comment.url or "")
	if url ~= "" then
		vim.ui.open(url)
		return true
	end
end

---@return boolean
function M.is_loading()
	return state.is_loading()
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	keymaps.setup(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	keymaps.teardown(buf)
	state.deactivate()
	notify.clear()
end

return M
