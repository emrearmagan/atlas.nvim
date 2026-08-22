---@class ConversationTab : PullsPRPanelTabModule
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
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	local request_generation = state.activate(pr)
	opts = opts or {}

	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.items = {}
		refresh()
		return
	end

	local id = tostring(pr.id or "")
	state.items = "loading"
	statusline.notify("loading", string.format("Loading conversation for #%s...", id))

	state.requests.run(function(done)
		return comments.fetch_conversation(pr, opts, done)
	end, function(result, err)
		if not state.is_current(request_generation, pr) then
			return
		end
		state.items = {}
		if result then
			for _, item in ipairs(result) do
				if item.kind ~= "comment" or item.entity.state ~= "DELETED" then
					table.insert(state.items, item)
				end
			end
		end

		state.error = nil
		if err then
			if not result then
				state.error = tostring(err)
			end
			local message = result and "Conversation for #%s partially failed: %s"
				or "Failed to load conversation for #%s: %s"
			statusline.notify("error", string.format(message, id, tostring(err)))
		else
			statusline.notify("success", string.format("Conversation loaded for #%s", id), 1200)
		end
		refresh()
	end)
end

M.render = renderer.render

---@param _lnum integer
---@param entry table
function M.is_selectable_line(_lnum, entry)
	return entry.conversation_item ~= nil or entry.kind == "activity_gap"
end

---@param _pr PullRequest
---@param entry table
function M.on_enter(_pr, entry)
	local item = entry and entry.conversation_item or nil
	if not item then
		return
	end
	local entity = item.entity
	local url = item.kind == "description" and tostring((entity.link or {}).html or "")
		or tostring(entity.html_url or entity.url or "")
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
