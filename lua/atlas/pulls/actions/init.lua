local M = {}

local git_checkout = require("atlas.core.git.checkout")
local icons = require("atlas.ui.shared.icons")
local md_editor = require("atlas.ui.popups.editor")
local picker = require("atlas.ui.picker")
local review = require("atlas.pulls.actions.review")
local utils = require("atlas.pulls.actions.utils")
local ui_utils = require("atlas.ui.shared.utils")

local has_pr = utils.has_pr
local notify = utils.notify

---@class PullsActionResult
---@field changed_pr boolean
---@field message string|nil

---@alias AtlasPullActionId
---| "copy_id"
---| "copy_url"
---| "open_in_browser"
---| "open_pipelines"
---| "open_diff"
---| "checkout"
---| "merge"
---| "decline"
---| "edit_title"
---| "edit_description"
---| "ready_for_review"
---| "convert_to_draft"
---| "edit_reviewers"
---| "search"
---| "search_pull_requests"
---| "approve"
---| "request_changes"

---@class AtlasPullActionContext
---@field provider PullsProvider
---@field pr PullRequest|nil
---@field details PullRequestDetails|nil
---@field current_user PullsUser|nil
---@field buf integer|nil
---@field notify fun(level: "loading"|"success"|"info"|"warn"|"error", message: string, duration: integer|nil)|nil

---@class AtlasPullAction
---@field id string
---@field label string
---@field icon string|nil
---@field hidden boolean|nil
---@field custom boolean|nil
---@field is_available (fun(context: AtlasPullActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasPullActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil))

---@param draft boolean
---@return AtlasPullAction
local function draft_action(draft)
	local id = draft and "convert_to_draft" or "ready_for_review"
	local label = draft and "Convert to draft" or "Mark as ready for review"
	return {
		id = id,
		label = label,
		icon = icons.action(draft and "edit" or "review"),
		is_available = function(context)
			if not context.pr then
				return false, "No PR selected"
			end
			if draft and context.pr.state ~= "open" then
				return false, "PR is not open"
			end
			if not draft and context.pr.state ~= "draft" then
				return false, "PR is not a draft"
			end
			return true
		end,
		run = function(context, done)
			local pr = assert(context.pr)
			notify(context, "loading", draft and "Converting to draft..." or "Marking as ready...")
			context.provider.capabilities.core.set_draft(pr, draft, function(ok, err)
				if err or ok == false then
					local message = tostring(err or "Unknown error")
					notify(context, "error", label .. " failed: " .. message)
					done(nil, message)
					return
				end
				pr.state = draft and "draft" or "open"
				notify(context, "success", draft and "PR converted to draft" or "PR marked as ready for review", 1200)
				done({ changed_pr = true, message = label }, nil)
			end)
		end,
	}
end

---@param id string
---@param context AtlasPullActionContext
---@return boolean
function M.is_available(id, context)
	local actions = context.provider.capabilities.actions
	return actions ~= nil and actions.is_available(id, context)
end

---@param id string
---@param context AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
---@return boolean handled
function M.run(id, context, on_done)
	local actions = context.provider.capabilities.actions
	if not actions then
		return false
	end
	return actions.run(id, context, on_done or function() end)
end

---@param context AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
function M.open(context, on_done)
	local actions = context.provider.capabilities.actions
	local items = {}
	for _, action in ipairs(actions and actions.items or {}) do
		if not action.hidden and M.is_available(action.id, context) then
			table.insert(items, action)
		end
	end
	vim.list_extend(items, utils.custom_actions(context))
	if #items == 0 then
		if on_done then
			on_done(nil, "No actions available")
		end
		return
	end

	local target = context.pr and string.format(" for #%s", tostring(context.pr.id)) or ""
	picker.select({
		title = string.format("Choose %s action%s", context.provider.name, target),
		items = items,
		format_item = icons.format_action,
		on_select = function(action)
			if not action then
				if on_done then
					on_done({ changed_pr = false, message = "Cancelled" }, nil)
				end
				return
			end
			if action.custom then
				action.run(context, on_done or function() end)
				return
			end
			M.run(action.id, context, on_done)
		end,
	})
end

M.edit_title = {
	id = "edit_title",
	label = "Edit title",
	icon = icons.action("edit"),
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		local original_title = pr.title
		md_editor.open({
			key = "pr-title-edit-" .. tostring(pr.id),
			title = " Edit Title ",
			width_ratio = 0.5,
			height_ratio = 0.12,
			initial_text = pr.title or "",
			on_save = function(text)
				local title = text and vim.trim(text) or ""
				if title == "" or title == pr.title then
					done({ changed_pr = false }, nil)
					return
				end
				notify(context, "loading", "Updating title...")
				context.provider.capabilities.core.update_title(pr, title, function(ok, err)
					if err or ok == false then
						local message = tostring(err or "Unknown error")
						notify(context, "error", "Title update failed: " .. message)
						done(nil, message)
						return
					end
					if pr.title == original_title then
						pr.title = title
					end
					notify(context, "success", "Title updated", 1200)
					done({ changed_pr = true, message = "Title updated" }, nil)
				end)
			end,
			on_cancel = function()
				done({ changed_pr = false }, nil)
			end,
		})
	end,
}

M.edit_description = {
	id = "edit_description",
	label = "Edit description",
	icon = icons.action("edit"),
	is_available = function(context)
		if not has_pr(context) then
			return false, "No PR selected"
		end
		if context.provider.capabilities.core.update_description == nil then
			return false, "Provider does not support editing the description"
		end
		return true
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		local core = context.provider.capabilities.core

		---@param current string
		local function edit(current)
			current = ui_utils.normalize_newlines(current)
			md_editor.open({
				key = "pr-description-edit-" .. tostring(pr.id),
				title = " Edit Description ",
				initial_text = current,
				on_save = function(text)
					local description = text or ""
					if description == current then
						notify(context, "info", "Description unchanged", 1200)
						done({ changed_pr = false, message = "No changes" }, nil)
						return
					end
					notify(context, "loading", "Updating description...")
					core.update_description(pr, description, function(ok, err)
						if err or ok == false then
							local message = tostring(err or "Unknown error")
							notify(context, "error", "Description update failed: " .. message)
							done(nil, message)
							return
						end
						if context.details then
							context.details.description = description
						end
						notify(context, "success", "Description updated", 1200)
						done({ changed_pr = true, message = "Description updated" }, nil)
					end)
				end,
				on_cancel = function()
					notify(context, "info", "Description unchanged", 1200)
					done({ changed_pr = false }, nil)
				end,
			})
		end

		-- Always edit against the remote description so a stale panel does not
		-- silently revert someone else's edit.
		notify(context, "loading", "Loading description...")
		core.fetch_description(pr, { force_refresh = true }, function(description, err)
			if err then
				local message = tostring(err)
				notify(context, "error", "Failed to load description: " .. message)
				done(nil, message)
				return
			end
			edit(tostring(description or ""))
		end)
	end,
}

M.ready_for_review = draft_action(false)
M.convert_to_draft = draft_action(true)

M.decline = {
	id = "decline",
	label = "Decline",
	icon = icons.action("close"),
	is_available = function(context)
		return context.pr ~= nil and (context.pr.state == "open" or context.pr.state == "draft")
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		vim.ui.input({ prompt = string.format("Decline PR #%s? [y/N]: ", tostring(pr.id)) }, function(input)
			if not input or not vim.trim(input):lower():match("^y") then
				done({ changed_pr = false, message = "Decline cancelled" }, nil)
				return
			end
			notify(context, "loading", "Declining PR...")
			context.provider.capabilities.core.decline(pr, function(ok, err)
				if not ok then
					local message = tostring(err or "Decline failed")
					notify(context, "error", message)
					done(nil, message)
					return
				end
				pr.state = "declined"
				notify(context, "success", "PR declined", 1200)
				done({ changed_pr = true, message = "Declined" }, nil)
			end)
		end)
	end,
}

M.edit_reviewers = {
	id = "edit_reviewers",
	label = "Edit reviewers",
	icon = icons.action("user"),
	is_available = function(context)
		if not context.pr then
			return false, "No PR selected"
		end
		local state = context.pr.state
		return state == "open" or state == "draft", "PR is not open"
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		local core = context.provider.capabilities.core

		notify(context, "loading", "Loading reviewers...")
		core.fetch_default_reviewers({
			repo_slug = pr.repo_full_name,
			repo_root = nil,
			head = pr.source.branch,
			base = pr.destination.branch,
			pr = pr,
		}, function(reviewers, err)
			if err then
				notify(context, "error", "Failed to load reviewers: " .. tostring(err))
				done(nil, err)
				return
			end

			reviewers = reviewers or {}
			if #reviewers == 0 then
				notify(context, "warn", "No reviewers available")
				done({ changed_pr = false, message = "No reviewers available" }, nil)
				return
			end

			local original = {}
			for _, reviewer in ipairs(reviewers) do
				if reviewer.selected then
					table.insert(original, reviewer)
				end
			end
			notify(context, "success", "Reviewers loaded", 1200)

			picker.multi_select({
				items = reviewers,
				selected = original,
				key = function(reviewer)
					return reviewer.provider_id
				end,
				format_item = function(reviewer)
					return reviewer.label
				end,
				title = string.format("Reviewers for #%s", tostring(pr.id or "")),
				on_done = function(chosen)
					local changed = #chosen ~= #original
					if not changed then
						local chosen_ids = {}
						for _, reviewer in ipairs(chosen) do
							chosen_ids[reviewer.provider_id] = true
						end
						for _, reviewer in ipairs(original) do
							if not chosen_ids[reviewer.provider_id] then
								changed = true
								break
							end
						end
					end
					if not changed then
						done({ changed_pr = false, message = "No changes" }, nil)
						return
					end

					notify(context, "loading", "Updating reviewers...")
					core.update_reviewers(pr, chosen, original, function(ok, update_err)
						if update_err or ok == false then
							local message = tostring(update_err or "Unknown error")
							notify(context, "error", "Update reviewers failed: " .. message)
							done(nil, message)
							return
						end
						notify(context, "success", "Reviewers updated", 1200)
						done({ changed_pr = true, message = "Reviewers updated" }, nil)
					end)
				end,
			})
		end)
	end,
}

M.open_pipelines = {
	id = "open_pipelines",
	label = "Open Pipelines",
	icon = icons.action("pipeline"),
	is_available = function(context)
		return has_pr(context) and context.provider.capabilities.pipelines ~= nil
	end,
	run = function(context, done)
		require("atlas.pulls.ui.pipelines").open(assert(context.pr), context.provider)
		notify(context, "success", "Opened Pipelines", 1200)
		done({ changed_pr = false, message = "Opened Pipelines" }, nil)
	end,
}

M.open_diff = {
	id = "open_diff",
	label = "Open diff",
	icon = icons.action("changes"),
	is_available = has_pr,
	run = function(context, done)
		require("atlas.pulls.diff").open_pr({
			ref = assert(context.pr),
			provider = context.provider,
			current_user = context.current_user,
		}, function(err)
			if err then
				notify(context, "error", "Unable to open diff: " .. tostring(err))
				done(nil, err)
				return
			end
			done({ changed_pr = false, message = "Opened diff" }, nil)
		end)
	end,
}

M.checkout = {
	id = "checkout",
	label = "Checkout PR branch",
	icon = icons.action("checkout"),
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)

		---@param selected PullRequest
		local function checkout(selected)
			notify(context, "loading", string.format("Checking out PR #%s", tostring(selected.id or "")))
			git_checkout.checkout_pr(selected, function(_, err)
				vim.schedule(function()
					if err then
						notify(context, "error", string.format("Checkout failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end
					notify(context, "success", string.format("Checked out PR #%s", tostring(selected.id or "")))
					done({ changed_pr = false, message = "Checked out PR" }, nil)
				end)
			end)
		end

		if pr.source.commit_hash ~= "" and pr.destination.commit_hash ~= "" then
			checkout(pr)
			return
		end

		notify(context, "loading", "Loading pull request revisions...")
		context.provider.capabilities.core.fetch_by_refs({ pr }, { force_refresh = false }, function(pulls, err)
			local fresh = pulls and pulls[1] or nil
			if fresh == nil then
				local message = tostring(err or "Unable to load pull request revisions")
				notify(context, "error", message)
				done(nil, message)
				return
			end
			checkout(fresh)
		end)
	end,
}

M.copy_id = utils.copy_id
M.copy_url = utils.copy_url
M.open_in_browser = utils.open_in_browser
M.start_review = review.start_review
M.submit_review = review.submit_review
M.approve = review.approve
M.request_changes = review.request_changes
M.discard_review = review.discard_review

return M
