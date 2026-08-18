local M = {}

local picker = require("atlas.picker")
local statusline = require("atlas.ui.statusline")
local review = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.panel.pr.tabs.conversation.state")

---@return PullsProvider|nil
local function get_provider()
	return require("atlas.pulls.state").provider
end

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(pr)
	local provider = get_provider()
	local comments_capability = provider and provider.capabilities.comments
	if not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local reviewers = require("atlas.pulls.ui.panel.pr.tabs.overview.state").reviewers
	local conversation = type(state.comments) == "table" and state.comments or {}
	return comments_capability.comment_completion({
		pr = pr,
		comments = conversation,
		tasks = type(state.tasks) == "table" and state.tasks or nil,
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = conversation,
	})
end

---@param fn fun(list: PullsComment[])
local function with_comments(fn)
	local list = state.comments
	if type(list) ~= "table" then
		return
	end
	---@cast list PullsComment[]
	fn(list)
end

---@param pr PullRequest
---@param item PullsComment|nil
---@return AtlasReviewActionContext|nil
local function action_context(pr, item)
	local provider = get_provider()
	if not provider then
		return nil
	end
	local items = item and item.is_task and state.tasks or state.comments
	items = type(items) == "table" and items or nil
	return {
		provider = provider,
		pr = pr,
		items = items,
		completion = author_completion(pr),
	}
end

---@param pr PullRequest
---@param refresh fun()
---@return fun(result: PullsActionResult|nil, err: string|nil)
local function on_done(pr, refresh)
	return function(result, err)
		if not result or err then
			return
		end
		if result.changed_pr then
			require("atlas.pulls.ui.main.controller").refresh_pr(pr)
		else
			refresh()
		end
	end
end

---@param pr PullRequest
---@param refresh fun()
function M.add(pr, refresh)
	local context = action_context(pr, nil)
	if context then
		review.add_comment(context, nil, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local context = action_context(pr, entry.comment)
	if context then
		review.add_comment(context, { parent = entry.comment }, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit(pr, entry, refresh)
	if not entry or (entry.entity_kind ~= "comment" and entry.entity_kind ~= "task") or not entry.comment then
		return
	end
	local context = action_context(pr, entry.comment)
	if context then
		review.edit_comment(context, entry.comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete(pr, entry, refresh)
	if not entry or (entry.entity_kind ~= "comment" and entry.entity_kind ~= "task") or not entry.comment then
		return
	end
	local comment = entry.comment
	if tostring(comment.id) == "__body__" then
		statusline.notify("info", "The pull request description cannot be deleted", 1200)
		return
	end
	local context = action_context(pr, comment)
	if context then
		review.delete_comment(context, comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.react(pr, entry, refresh)
	if not entry or entry.entity_kind ~= "comment" or not entry.comment then
		return
	end
	local provider = get_provider()
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_reaction then
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		statusline.notify("warn", "No reactions available for this provider")
		return
	end
	local comment = entry.comment
	local choices = {}
	for _, option in ipairs(options) do
		table.insert(choices, {
			key = option.key,
			label = string.format("%s  %s", option.emoji or option.key, option.label or option.key),
		})
	end
	picker.select({
		title = "Add reaction",
		items = choices,
		format_item = function(item)
			return item.label
		end,
		on_select = function(selected)
			if selected == nil then
				return
			end
			statusline.notify("loading", "Adding reaction...")
			comments.add_reaction(pr, comment, selected.key, function(ok, err)
				if err then
					statusline.notify("error", "Reaction failed: " .. tostring(err))
					return
				end
				if ok then
					with_comments(function(list)
						for _, current in ipairs(list) do
							if current.id == comment.id then
								current.reactions = current.reactions or {}
								current.reactions[selected.key] = (tonumber(current.reactions[selected.key]) or 0) + 1
								break
							end
						end
					end)
				end
				statusline.notify("success", "Reaction added", 1200)
				refresh()
			end)
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.toggle_task(pr, entry, refresh)
	local task = entry and entry.entity_kind == "task" and entry.comment or nil
	if not task then
		return
	end
	local context = action_context(pr, task)
	if context then
		review.toggle_task(context, task, on_done(pr, refresh))
	end
end

return M
