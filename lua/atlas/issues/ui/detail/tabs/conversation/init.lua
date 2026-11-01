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
		state.conversation = { comments = {}, activities = {} }
		refresh()
		return
	end

	local key = issue.key
	state.conversation = "loading"
	notify.loading(string.format("Loading conversation for %s...", key))
	state.requests.run(function(done)
		return comments.fetch_conversation(issue, opts, done)
	end, function(result, err)
		if not state.is_current(issue) then
			return
		end
		state.conversation = nil
		if result then
			local visible = {}
			for _, comment in ipairs(result.comments) do
				if comment.deleted ~= true then
					table.insert(visible, comment)
				end
			end
			state.conversation =
				{ description = result.description, comments = visible, activities = result.activities }
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
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.comment ~= nil or entry.activity_entry ~= nil or entry.kind == "activity_gap"
end

---@param _issue Issue
---@param entry IssuesConversationLine|nil
---@return boolean|nil
function M.on_enter(_issue, entry)
	local comment = entry and entry.comment
	local url = comment and tostring(comment.url or "") or ""
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
