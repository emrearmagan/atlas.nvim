local M = {}

local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local renderer = require("atlas.pulls.ui.detail.tabs.conversation.renderer")
local keymaps = require("atlas.pulls.ui.detail.tabs.conversation.keymaps")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.detail.state")

M.reset = state.reset

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}
	if state.conversation ~= nil and not opts.force_refresh then
		return
	end

	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.conversation = { comments = {}, reviews = {}, activities = {} }
		refresh()
		return
	end

	local id = tostring(pr.id or "")
	state.conversation = "loading"

	state.requests.run(function(done)
		return comments.fetch_conversation(pr, opts, done)
	end, function(result, err)
		state.conversation = result
			and {
				description = result.description,
				comments = vim.list_extend({}, result.comments),
				reviews = result.reviews,
				activities = result.activities,
			}

		state.error = nil
		if err then
			if not result then
				state.error = tostring(err)
			end
			local message = result and "Conversation for #%s partially failed: %s"
				or "Failed to load conversation for #%s: %s"
			notify.error(string.format(message, id, tostring(err)))
		end
		refresh()
	end)
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry)
	return entry.comment ~= nil
		or entry.review_entry ~= nil
		or entry.activity_entry ~= nil
		or entry.kind == "activity_gap"
end

---@param _pr PullRequest
---@param entry PullsConversationLine|nil
function M.on_enter(_pr, entry)
	local subject = entry and (entry.comment or entry.review_entry)
	local url = subject and subject.url
	if url and url ~= "" then
		vim.ui.open(url)
		return true
	end
end

---@return boolean
function M.is_loading()
	return state.conversation == "loading"
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	keymaps.setup(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	keymaps.teardown(buf)
end

return M
