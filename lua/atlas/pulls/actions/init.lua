local action_runner = require("atlas.core.actions")
local diff = require("atlas.pulls.diff")
local git_checkout = require("atlas.core.git.checkout")
local icons = require("atlas.ui.shared.icons")
local merge_buffer = require("atlas.pulls.ui.merge")
local notes = require("atlas.pulls.notes")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local pipeline_api = require("atlas.pulls.pipelines")
local repository = require("atlas.ui.repository")
local review = require("atlas.pulls.actions.review")
local reviewed_store = require("atlas.pulls.reviewed")
local utils = require("atlas.pulls.actions.utils")

local M = {}

local has_pr = utils.has_pr

---@class PullsActionResult
---@field changed_pr boolean

---@alias AtlasPullActionId
---| "copy_id"
---| "copy_url"
---| "open_in_browser"
---| "open_pipelines"
---| "browse_repository"
---| "browse_repositories"
---| "open_diff"
---| "checkout"
---| "merge"
---| "decline"
---| "edit_pr"
---| "ready_for_review"
---| "convert_to_draft"
---| "edit_reviewers"
---| "search"
---| "search_pull_requests"
---| "edit_search"
---| "approve"
---| "request_changes"

---@class AtlasPullActionContext
---@field provider PullsProvider
---@field pr PullRequest|nil
---@field details PullRequestDetails|nil
---@field current_user AtlasUser|nil
---@field buf integer|nil
---@field page string|nil Repository page for `browse_repositories`

---@class AtlasPullAction: AtlasAction
---@field is_available (fun(context: AtlasPullActionContext): boolean, string|nil)|nil
---@field run fun(context: AtlasPullActionContext, on_done: fun(result: PullsActionResult|nil, err: string|nil)): boolean|nil

---@param draft boolean
---@return AtlasPullAction
local function draft_action(draft)
	local id = draft and "convert_to_draft" or "ready_for_review"
	local label = draft and "Convert to draft" or "Mark as ready for review"
	return {
		id = id,
		label = label,
		icon = draft and icons.get("draft_pr") or icons.get("review", "actions"),
		is_available = function(context)
			if not context.pr then
				return false, "No PR selected"
			end
			local write = context.provider.capabilities.write
			if not write or not write.update then
				return false, "Provider does not support editing pull requests"
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
			notify.loading(draft and "Converting to draft..." or "Marking as ready...")
			context.provider.capabilities.write.update(pr, { draft = draft }, function(ok, err)
				if err or ok == false then
					local message = tostring(err or "Unknown error")
					notify.error(label .. " failed: " .. message)
					done(nil, message)
					return
				end
				pr.state = draft and "draft" or "open"
				notify.success(draft and "PR converted to draft" or "PR marked as ready for review", { timeout = 1200 })
				done({ changed_pr = true }, nil)
			end)
		end,
	}
end

---@param id string
---@param context AtlasPullActionContext
---@return AtlasAction|nil
function M.find(id, context)
	return action_runner.find(utils.custom_actions(), id)
		or action_runner.find(context.provider.capabilities.actions, id)
end

---@param id string
---@param context AtlasPullActionContext
---@return boolean
function M.is_available(id, context)
	return action_runner.is_available(M.find(id, context), context)
end

---@param id string
---@param context AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
---@return boolean handled
function M.run(id, context, on_done)
	return action_runner.run(M.find(id, context), context, on_done)
end

---@param context AtlasPullActionContext
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
---@param extra_items { label: string, icon?: string, callback: fun() }[]|nil
function M.open(context, on_done, extra_items)
	local custom = utils.custom_actions()
	local items = {}
	for _, action in ipairs(context.provider.capabilities.actions or {}) do
		if not action.hidden and not action_runner.find(custom, action.id) then
			table.insert(items, action)
		end
	end
	vim.list_extend(items, custom)
	items = vim.tbl_filter(function(action)
		return action_runner.is_available(action, context)
	end, items)
	vim.list_extend(items, extra_items or {})
	if #items == 0 then
		notify.info("No actions available")
		return
	end

	local target = context.pr and string.format(" for #%s", tostring(context.pr.id)) or ""
	action_runner.select(string.format("Choose %s action%s", context.provider.name, target), items, function(item)
		if item.callback then
			item.callback()
		else
			action_runner.run(item, context, on_done)
		end
	end)
end

M.edit_pr = {
	id = "edit_pr",
	label = "Edit PR",
	icon = icons.get("edit", "actions"),
	is_available = function(context)
		if not context.pr then
			return false, "No PR selected"
		end
		local write = context.provider.capabilities.write
		return write ~= nil and write.update ~= nil, "Provider does not support editing pull requests"
	end,
	run = function(context, done)
		require("atlas.pulls.editor").edit(context.provider, assert(context.pr), function(changed, err)
			if err then
				done(nil, err)
				return
			end
			done({ changed_pr = changed }, nil)
		end)
	end,
}

M.ready_for_review = draft_action(false)
M.convert_to_draft = draft_action(true)

M.merge = {
	id = "merge",
	label = "Merge",
	icon = icons.get("merge", "actions"),
	is_available = function(context)
		return context.pr ~= nil and context.pr.state == "open" and context.provider.capabilities.core.merge ~= nil
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		local core = context.provider.capabilities.core
		merge_buffer.open(pr, {
			on_cancel = function()
				done({ changed_pr = false }, nil)
			end,
			on_submit = function(options, completed)
				notify.loading("Merging...")
				core.merge(pr, options, function(ok, merge_err)
					if not ok or merge_err then
						notify.error("Merge failed: " .. tostring(merge_err or "Unknown error"))
						completed(false)
						return
					end
					notes.clear(pr)
					reviewed_store.clear(pr)
					completed(true)
					notify.success("Merge succeeded", { timeout = 1200 })
					done({ changed_pr = true }, nil)
				end)
			end,
		})
	end,
}

M.decline = {
	id = "decline",
	label = "Decline",
	icon = icons.get("close", "actions"),
	confirm = function(context)
		return string.format("Decline PR #%s?", tostring(assert(context.pr).id))
	end,
	is_available = function(context)
		return context.pr ~= nil and (context.pr.state == "open" or context.pr.state == "draft")
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		notify.loading("Declining PR...")
		context.provider.capabilities.core.decline(pr, function(ok, err)
			if not ok then
				local message = tostring(err or "Decline failed")
				notify.error(message)
				done(nil, message)
				return
			end
			pr.state = "declined"
			notes.clear(pr)
			reviewed_store.clear(pr)
			notify.success("PR declined", { timeout = 1200 })
			done({ changed_pr = true }, nil)
		end)
	end,
}

M.edit_reviewers = {
	id = "edit_reviewers",
	label = "Edit reviewers",
	icon = icons.get("user", "actions"),
	is_available = function(context)
		if not context.pr then
			return false, "No PR selected"
		end
		local write = context.provider.capabilities.write
		if not write or not write.update or not write.fetch_reviewer_candidates then
			return false, "Provider does not support editing reviewers"
		end
		local state = context.pr.state
		return state == "open" or state == "draft", "PR is not open"
	end,
	run = function(context, done)
		local pr = assert(context.pr)
		local write = context.provider.capabilities.write

		notify.loading("Loading reviewers...")
		write.fetch_reviewer_candidates({
			repo_slug = pr.repo_full_name,
			pr = pr,
		}, function(reviewers, err)
			if err then
				notify.error("Failed to load reviewers: " .. tostring(err))
				done(nil, err)
				return
			end

			reviewers = reviewers or {}
			if #reviewers == 0 then
				notify.warn("No reviewers available")
				done({ changed_pr = false }, nil)
				return
			end

			local original = {}
			for _, reviewer in ipairs(reviewers) do
				if reviewer.selected then
					table.insert(original, reviewer)
				end
			end
			notify.success("Reviewers loaded", { timeout = 1200 })

			picker.multi_select({
				items = reviewers,
				selected = original,
				key = function(reviewer)
					return reviewer.provider_id
				end,
				format_item = function(reviewer)
					return reviewer.label
				end,
				title = string.format("Reviewers for #%s", tostring(pr.id)),
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
						done({ changed_pr = false }, nil)
						return
					end

					notify.loading("Updating reviewers...")
					write.update(pr, { reviewers = chosen }, function(ok, update_err)
						if update_err or ok == false then
							local message = tostring(update_err or "Unknown error")
							notify.error("Update reviewers failed: " .. message)
							done(nil, message)
							return
						end
						notify.success("Reviewers updated", { timeout = 1200 })
						done({ changed_pr = true }, nil)
					end)
				end,
			})
		end)
	end,
}

M.browse_repository = {
	id = "browse_repository",
	label = "Browse Current Repository",
	icon = icons.get("overview"),
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		repository.open(pr.repo_full_name, context.provider)
		done({ changed_pr = false }, nil)
	end,
}

M.open_pipelines = {
	id = "open_pipelines",
	label = "Open Pipelines",
	icon = icons.get("pipeline", "actions"),
	is_available = function(context)
		if not has_pr(context) then
			return false
		end
		return pipeline_api.get(context.provider) ~= nil
	end,
	run = function(context, done)
		pipeline_api.open(assert(context.pr), context.provider)
		done({ changed_pr = false }, nil)
	end,
}

M.open_diff = {
	id = "open_diff",
	label = "Open diff",
	icon = icons.get("changes", "actions"),
	is_available = has_pr,
	run = function(context, done)
		diff.open_pr(context.pr, function(err)
			if err then
				notify.error("Unable to open diff: " .. tostring(err))
				done(nil, err)
				return
			end
			done({ changed_pr = false }, nil)
		end)
	end,
}

M.checkout = {
	id = "checkout",
	label = "Checkout PR branch",
	icon = icons.get("checkout", "actions"),
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)

		---@param selected PullRequest
		local function checkout(selected)
			notify.loading(string.format("Checking out PR #%s", tostring(selected.id)))
			git_checkout.checkout_pr(selected, function(_, err)
				vim.schedule(function()
					if err then
						notify.error(string.format("Checkout failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end
					notify.success(string.format("Checked out PR #%s", tostring(selected.id)))
					done({ changed_pr = false }, nil)
				end)
			end)
		end

		if pr.source.commit_hash ~= "" and pr.destination.commit_hash ~= "" then
			checkout(pr)
			return
		end

		notify.loading("Loading pull request revisions...")
		context.provider.capabilities.core.fetch_by_refs({ pr }, { force_refresh = false }, function(pulls, err)
			local fresh = pulls and pulls[1] or nil
			if fresh == nil then
				local message = tostring(err or "Unable to load pull request revisions")
				notify.error(message)
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
