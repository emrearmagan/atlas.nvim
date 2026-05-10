local M = {}

local icons = require("atlas.ui.shared.icons")
local footer = require("atlas.ui.components.footer")
local multi_select = require("atlas.ui.popups.multi_select")
local mr_api = require("atlas.pulls.providers.gitlab.api.mergerequests")
local users_api = require("atlas.pulls.providers.gitlab.api.users")

---@param ctx table
---@return boolean
local function has_pr(ctx)
	return type(ctx) == "table" and type(ctx.pr) == "table"
end

---@param pr PullRequest
---@return string
local function project_path(pr)
	local raw = type(pr._raw) == "table" and pr._raw or {}
	local path = tostring(raw.project_path or pr.repo_full_name or "")
	return path
end

---@param pr PullRequest
---@return string
local function pr_label(pr)
	local path = project_path(pr)
	if path ~= "" then
		return string.format("%s!%s", path, tostring(pr.id or ""))
	end
	return string.format("!%s", tostring(pr.id or ""))
end

---@param title string
---@return string
local function strip_draft_prefix(title)
	local stripped = (tostring(title or "")):gsub("^%s*[Dd]raft:%s*", ""):gsub("^%s*WIP:%s*", "")
	return stripped
end

---@param title string
---@return boolean
local function is_draft_title(title)
	local t = tostring(title or "")
	return t:match("^%s*[Dd]raft:") ~= nil or t:match("^%s*WIP:") ~= nil
end

---@param ctx table
---@return boolean
local function is_open(ctx)
	return has_pr(ctx) and ctx.pr.state == "open"
end

---@param ctx table
---@return boolean
local function is_open_or_draft(ctx)
	return has_pr(ctx) and (ctx.pr.state == "open" or ctx.pr.state == "draft")
end

local ACTIONS = {
	{
		id = "merge",
		label = "Merge MR",
		is_available = function(ctx)
			if not has_pr(ctx) then
				return false, "No MR selected"
			end
			if ctx.pr.state == "draft" then
				return false, "MR is a draft"
			end
			if ctx.pr.state ~= "open" then
				return false, "MR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			vim.ui.input({ prompt = string.format("Merge %s? Squash? [n/y]: ", pr_label(pr)) }, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Merge cancelled" }, nil)
					return
				end
				local squash = vim.trim(tostring(input)):lower() == "y"
				footer.notify("loading", string.format("Merging %s...", pr_label(pr)))
				mr_api.merge(pr, {
					squash = squash,
					should_remove_source_branch = true,
				}, function(ok, err)
					if not ok then
						footer.notify("error", err or "Merge failed")
						done(nil, err or "Merge failed")
						return
					end
					footer.notify("success", string.format("Merged %s", pr_label(pr)), 1500)
					done({ changed_pr = true, message = "Merged" }, nil)
				end)
			end)
		end,
	},
	{
		id = "approve",
		label = "Approve MR",
		is_available = function(ctx)
			if not is_open_or_draft(ctx) then
				return false, "MR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			footer.notify("loading", string.format("Approving %s...", pr_label(pr)))
			mr_api.approve(pr, function(ok, err)
				if not ok then
					footer.notify("error", err or "Approve failed")
					done(nil, err or "Approve failed")
					return
				end
				footer.notify("success", string.format("Approved %s", pr_label(pr)), 1200)
				done({ changed_pr = true, message = "Approved" }, nil)
			end)
		end,
	},
	{
		id = "unapprove",
		label = "Unapprove MR",
		is_available = function(ctx)
			if not is_open_or_draft(ctx) then
				return false, "MR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			footer.notify("loading", string.format("Unapproving %s...", pr_label(pr)))
			mr_api.unapprove(pr, function(ok, err)
				if not ok then
					footer.notify("error", err or "Unapprove failed")
					done(nil, err or "Unapprove failed")
					return
				end
				footer.notify("success", string.format("Unapproved %s", pr_label(pr)), 1200)
				done({ changed_pr = true, message = "Unapproved" }, nil)
			end)
		end,
	},
	{
		id = "close",
		label = "Close MR",
		is_available = function(ctx)
			if not is_open_or_draft(ctx) then
				return false, "MR is already closed/merged"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			footer.notify("loading", string.format("Closing %s...", pr_label(pr)))
			mr_api.set_state(pr, "close", function(ok, err)
				if not ok then
					footer.notify("error", err or "Close failed")
					done(nil, err or "Close failed")
					return
				end
				footer.notify("success", string.format("Closed %s", pr_label(pr)), 1200)
				done({ changed_pr = true, message = "Closed" }, nil)
			end)
		end,
	},
	{
		id = "reopen",
		label = "Reopen MR",
		is_available = function(ctx)
			if not has_pr(ctx) then
				return false, "No MR selected"
			end
			if ctx.pr.state ~= "declined" then
				return false, "MR is not closed"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			footer.notify("loading", string.format("Reopening %s...", pr_label(pr)))
			mr_api.set_state(pr, "reopen", function(ok, err)
				if not ok then
					footer.notify("error", err or "Reopen failed")
					done(nil, err or "Reopen failed")
					return
				end
				footer.notify("success", string.format("Reopened %s", pr_label(pr)), 1200)
				done({ changed_pr = true, message = "Reopened" }, nil)
			end)
		end,
	},
	{
		id = "convert_to_draft",
		label = "Convert to draft",
		is_available = function(ctx)
			if not is_open(ctx) then
				return false, "MR is not open"
			end
			if is_draft_title(ctx.pr.title) then
				return false, "MR is already a draft"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			local new_title = "Draft: " .. strip_draft_prefix(pr.title)
			footer.notify("loading", string.format("Marking %s as draft...", pr_label(pr)))
			mr_api.set_title(pr, new_title, function(ok, err)
				if not ok then
					footer.notify("error", err or "Failed")
					done(nil, err or "Failed")
					return
				end
				footer.notify("success", "Marked as draft", 1200)
				done({ changed_pr = true, message = "Marked as draft" }, nil)
			end)
		end,
	},
	{
		id = "ready_for_review",
		label = "Mark as ready for review",
		is_available = function(ctx)
			if not has_pr(ctx) then
				return false, "No MR selected"
			end
			if not is_draft_title(ctx.pr.title) and ctx.pr.state ~= "draft" then
				return false, "MR is not a draft"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			local new_title = strip_draft_prefix(pr.title)
			if new_title == "" then
				done(nil, "MR title is empty after stripping draft prefix")
				return
			end
			footer.notify("loading", string.format("Marking %s ready for review...", pr_label(pr)))
			mr_api.set_title(pr, new_title, function(ok, err)
				if not ok then
					footer.notify("error", err or "Failed")
					done(nil, err or "Failed")
					return
				end
				footer.notify("success", "Marked as ready", 1200)
				done({ changed_pr = true, message = "Marked as ready" }, nil)
			end)
		end,
	},
	{
		id = "edit_reviewers",
		label = "Edit reviewers",
		is_available = function(ctx)
			if not is_open_or_draft(ctx) then
				return false, "MR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			local path = project_path(pr)
			if path == "" then
				done(nil, "Could not determine project path")
				return
			end

			footer.notify("loading", "Loading members...")
			users_api.list_members(path, "", function(members, err)
				if err or members == nil then
					footer.notify("error", err or "Failed to load members")
					done(nil, err or "Failed to load members")
					return
				end
				footer.notify("info", "", 0)
				if #members == 0 then
					done(nil, "No assignable members")
					return
				end

				local raw = pr._raw or {}
				local original = {}
				local original_set = {}
				for _, r in ipairs(raw.reviewers or {}) do
					local id = tonumber(r.id)
					if id then
						table.insert(original, { id = id, username = r.username, name = r.name or r.username })
						original_set[id] = true
					end
				end

				multi_select.open({
					items = members,
					selected = vim.deepcopy(original),
					key = function(item)
						return tostring(item.id or "")
					end,
					format = function(item)
						return string.format("%s %s (@%s)", icons.general("user"), item.name or item.username, item.username)
					end,
					prompt = string.format("Reviewers for %s", pr_label(pr)),
					on_done = function(selected)
						local final_ids = {}
						local final_set = {}
						for _, it in ipairs(selected) do
							local id = tonumber(it.id)
							if id then
								table.insert(final_ids, id)
								final_set[id] = true
							end
						end

						local changed = false
						if #final_ids ~= #original then
							changed = true
						else
							for id, _ in pairs(original_set) do
								if not final_set[id] then
									changed = true
									break
								end
							end
						end

						if not changed then
							done({ changed_pr = false, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating reviewers on %s...", pr_label(pr)))
						mr_api.set_reviewer_ids(pr, final_ids, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("%d reviewer(s)", #final_ids)
							footer.notify("success", msg, 1200)
							done({ changed_pr = true, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "edit_assignees",
		label = "Edit assignees",
		is_available = function(ctx)
			if not is_open_or_draft(ctx) then
				return false, "MR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			local path = project_path(pr)
			if path == "" then
				done(nil, "Could not determine project path")
				return
			end

			footer.notify("loading", "Loading members...")
			users_api.list_members(path, "", function(members, err)
				if err or members == nil then
					footer.notify("error", err or "Failed to load members")
					done(nil, err or "Failed to load members")
					return
				end
				footer.notify("info", "", 0)
				if #members == 0 then
					done(nil, "No assignable members")
					return
				end

				local raw = pr._raw or {}
				local original = {}
				local original_set = {}
				for _, a in ipairs(raw.assignees or {}) do
					local id = tonumber(a.id)
					if id then
						table.insert(original, { id = id, username = a.username, name = a.name or a.username })
						original_set[id] = true
					end
				end

				multi_select.open({
					items = members,
					selected = vim.deepcopy(original),
					key = function(item)
						return tostring(item.id or "")
					end,
					format = function(item)
						return string.format("%s %s (@%s)", icons.general("user"), item.name or item.username, item.username)
					end,
					prompt = string.format("Assignees for %s", pr_label(pr)),
					on_done = function(selected)
						local final_ids = {}
						local final_set = {}
						for _, it in ipairs(selected) do
							local id = tonumber(it.id)
							if id then
								table.insert(final_ids, id)
								final_set[id] = true
							end
						end

						local changed = false
						if #final_ids ~= #original then
							changed = true
						else
							for id, _ in pairs(original_set) do
								if not final_set[id] then
									changed = true
									break
								end
							end
						end

						if not changed then
							done({ changed_pr = false, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating assignees on %s...", pr_label(pr)))
						mr_api.set_assignee_ids(pr, final_ids, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("%d assignee(s)", #final_ids)
							footer.notify("success", msg, 1200)
							done({ changed_pr = true, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
}

---@param ctx table
---@return table[]
function M.available(ctx)
	local out = {}
	for _, action in ipairs(ACTIONS) do
		if not action.hidden then
			local ok = action.is_available(ctx)
			if ok then
				table.insert(out, action)
			end
		end
	end

	-- Shared actions (from atlas.pulls.actions): open_diff, checkout
	if has_pr(ctx) then
		local shared_actions = require("atlas.pulls.actions")
		table.insert(out, {
			id = "open_diff",
			label = "Open diff",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.open_diff(action_ctx.pr)
				done({ changed_pr = false, message = "Opened diff" }, nil)
			end,
		})
		table.insert(out, {
			id = "checkout",
			label = "Checkout MR branch",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.checkout(action_ctx.pr)
				done({ changed_pr = false, message = "Checkout started" }, nil)
			end,
		})
	end

	-- Custom actions from config
	local pulls_cfg = require("atlas.config").options.pulls or {}
	local custom_actions = pulls_cfg.custom_actions or {}
	local pulls_state = require("atlas.pulls.state")

	for _, item in ipairs(custom_actions) do
		if type(item) == "table" and type(item.label) == "string" and type(item.run) == "function" then
			table.insert(out, {
				id = tostring(item.id or item.label),
				label = item.label,
				is_available = function(action_ctx)
					if not has_pr(action_ctx) then
						return false, "No MR selected"
					end
					return true, nil
				end,
				run = function(action_ctx, done)
					footer.notify("loading", string.format("Running %s...", tostring(item.label)))

					local done_called = false
					local function custom_done(ok, message)
						if done_called then
							return
						end
						done_called = true
						vim.schedule(function()
							if ok == false then
								footer.notify("error", tostring(message or (item.label .. " failed")))
								done(nil, tostring(message or (item.label .. " failed")))
								return
							end
							footer.notify("success", tostring(message or (item.label .. " done")))
							done({ changed_pr = false, message = tostring(message or (item.label .. " done")) }, nil)
						end)
					end

					local ok, err = pcall(item.run, action_ctx.pr, {
						pr = action_ctx.pr,
						user = pulls_state.current_user,
					}, custom_done)

					if not ok then
						custom_done(false, string.format("Custom action failed: %s", tostring(err)))
					end
				end,
			})
		end
	end

	return out
end

---@param id string
---@return table|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
