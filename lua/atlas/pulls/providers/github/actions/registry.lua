local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local footer = require("atlas.ui.components.footer")
local checkout = require("atlas.core.git.checkout")
local logger = require("atlas.core.logger")
local multi_select = require("atlas.ui.popups.multi_select")

---@class GitHubActionContext
---@field pr PullRequest|nil
---@field source "main"|"panel"|nil

---@class GitHubActionDef
---@field id GitHubActionId|string
---@field label string
---@field is_available fun(ctx: GitHubActionContext): boolean, string|nil
---@field run fun(ctx: GitHubActionContext, done: fun(result: PullsActionResult|nil, err: string|nil))

---@param ctx GitHubActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil and ctx.pr.id ~= nil
end

---@param ctx GitHubActionContext
---@return string
local function repo_slug(ctx)
	return tostring((ctx.pr or {}).repo_full_name or "")
end

---@type GitHubActionDef[]
local ACTIONS = {
	{
		id = "merge",
		label = "Merge",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			local slug = repo_slug(ctx)
			local strategies = { "merge", "squash", "rebase" }

			vim.ui.select(strategies, {
				prompt = string.format("Merge strategy for PR #%s:", tostring(pr.id or "")),
				kind = "atlas_github_merge_strategy",
			}, function(strategy)
				if strategy == nil then
					done({ changed_pr = false, message = "Merge cancelled" }, nil)
					return
				end

				vim.ui.input({
					prompt = string.format("Confirm %s merge PR #%s? [y/N]: ", strategy, tostring(pr.id or "")),
				}, function(input)
					if input == nil then
						done({ changed_pr = false, message = "Merge cancelled" }, nil)
						return
					end

					local normalized = vim.trim(tostring(input)):lower()
					if normalized ~= "y" and normalized ~= "yes" then
						footer.notify("info", "Merge cancelled")
						done({ changed_pr = false, message = "Merge cancelled" }, nil)
						return
					end

					footer.notify("loading", "Merging PR...")
					cli.gh({
						"pr",
						"merge",
						tostring(pr.id),
						"--repo",
						slug,
						"--" .. strategy,
						"--delete-branch",
					}, function(_, err)
						if err then
							footer.notify("error", string.format("Merge failed: %s", tostring(err)))
							done(nil, tostring(err))
							return
						end

						footer.notify("success", "Merge succeeded", 1200)
						done({ changed_pr = true, message = "Merged" }, nil)
					end)
				end)
			end)
		end,
	},
	{
		id = "approve",
		label = "Approve",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			footer.notify("loading", "Approving PR...")
			cli.gh({
				"pr",
				"review",
				tostring(pr.id),
				"--repo",
				repo_slug(ctx),
				"--approve",
			}, function(_, err)
				if err then
					footer.notify("error", string.format("Approve failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				footer.notify("success", "PR approved", 1200)
				done({ changed_pr = true, message = "Approved" }, nil)
			end)
		end,
	},
	{
		id = "request_changes",
		label = "Request changes",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			vim.ui.input({ prompt = "Reason for requesting changes: " }, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Cancelled" }, nil)
					return
				end

				local body = vim.trim(input)
				if body == "" then
					body = "Changes requested"
				end

				footer.notify("loading", "Requesting changes...")
				cli.gh({
					"pr",
					"review",
					tostring(pr.id),
					"--repo",
					repo_slug(ctx),
					"--request-changes",
					"--body",
					body,
				}, function(_, err)
					if err then
						footer.notify("error", string.format("Request changes failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end

					footer.notify("success", "Changes requested", 1200)
					done({ changed_pr = true, message = "Changes requested" }, nil)
				end)
			end)
		end,
	},
	{
		id = "close",
		label = "Close PR",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			local s = tostring(ctx.pr.state or ""):lower()
			if s ~= "open" and s ~= "draft" then
				return false, "PR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			vim.ui.input({
				prompt = string.format("Close PR #%s? [y/N]: ", tostring(pr.id or "")),
			}, function(input)
				if input == nil then
					done({ changed_pr = false, message = "Close cancelled" }, nil)
					return
				end

				local normalized = vim.trim(tostring(input)):lower()
				if normalized ~= "y" and normalized ~= "yes" then
					footer.notify("info", "Close cancelled")
					done({ changed_pr = false, message = "Close cancelled" }, nil)
					return
				end

				footer.notify("loading", "Closing PR...")
				cli.gh({
					"pr",
					"close",
					tostring(pr.id),
					"--repo",
					repo_slug(ctx),
				}, function(_, err)
					if err then
						footer.notify("error", string.format("Close failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end

					footer.notify("success", "PR closed", 1200)
					done({ changed_pr = true, message = "Closed" }, nil)
				end)
			end)
		end,
	},
	{
		id = "reopen",
		label = "Reopen PR",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			local s = tostring(ctx.pr.state or ""):lower()
			if s ~= "declined" then
				return false, "PR is not closed"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			footer.notify("loading", "Reopening PR...")
			cli.gh({
				"pr",
				"reopen",
				tostring(pr.id),
				"--repo",
				repo_slug(ctx),
			}, function(_, err)
				if err then
					footer.notify("error", string.format("Reopen failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				footer.notify("success", "PR reopened", 1200)
				done({ changed_pr = true, message = "Reopened" }, nil)
			end)
		end,
	},
	{
		id = "ready_for_review",
		label = "Mark as ready for review",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			if tostring(ctx.pr.state or ""):lower() ~= "draft" then
				return false, "PR is not a draft"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			footer.notify("loading", "Marking as ready...")
			cli.gh({
				"pr",
				"ready",
				tostring(pr.id),
				"--repo",
				repo_slug(ctx),
			}, function(_, err)
				if err then
					footer.notify("error", string.format("Failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				footer.notify("success", "PR marked as ready for review", 1200)
				done({ changed_pr = true, message = "Ready for review" }, nil)
			end)
		end,
	},
	{
		id = "convert_to_draft",
		label = "Convert to draft",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			if tostring(ctx.pr.state or ""):lower() ~= "open" then
				return false, "PR is not open"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			footer.notify("loading", "Converting to draft...")
			cli.gh({
				"pr",
				"ready",
				tostring(pr.id),
				"--repo",
				repo_slug(ctx),
				"--undo",
			}, function(_, err)
				if err then
					footer.notify("error", string.format("Failed: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				footer.notify("success", "PR converted to draft", 1200)
				done({ changed_pr = true, message = "Converted to draft" }, nil)
			end)
		end,
	},
	{
		id = "add_reviewers",
		label = "Add reviewers",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			local slug = repo_slug(ctx)

			footer.notify("loading", "Loading reviewers...")
			cli.gh({
				"api",
				"--paginate",
				string.format("repos/%s/collaborators?per_page=100", slug),
			}, function(result, err)
				if err then
					footer.notify("error", string.format("Failed to load reviewers: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				local items = {}
				if type(result) == "table" then
					for _, raw in ipairs(result) do
						if type(raw) == "table" and type(raw.login) == "string" then
							table.insert(items, { login = raw.login })
						end
					end
				end

				if #items == 0 then
					footer.notify("warn", "No reviewers available")
					done({ changed_pr = false, message = "No reviewers available" }, nil)
					return
				end

				multi_select.open({
					items = items,
					selected = {},
					key = function(item)
						return item.login
					end,
					format = function(item)
						return "@" .. tostring(item.login)
					end,
					prompt = string.format("Add reviewers to PR #%s:", tostring(pr.id or "")),
					on_done = function(selected)
						if #selected == 0 then
							done({ changed_pr = false, message = "No reviewers selected" }, nil)
							return
						end

						local args = { "pr", "edit", tostring(pr.id), "--repo", slug }
						for _, item in ipairs(selected) do
							table.insert(args, "--add-reviewer")
							table.insert(args, item.login)
						end

						footer.notify("loading", "Adding reviewers...")
						cli.gh(args, function(_, edit_err)
							if edit_err then
								footer.notify("error", string.format("Add reviewers failed: %s", tostring(edit_err)))
								done(nil, tostring(edit_err))
								return
							end

							footer.notify("success", string.format("Added %d reviewer(s)", #selected), 1200)
							done({ changed_pr = true, message = "Reviewers added" }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "add_assignees",
		label = "Add assignees",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end

			local slug = repo_slug(ctx)
			local issues_api = require("atlas.pulls.providers.github.api.issues")

			footer.notify("loading", "Loading assignees...")
			issues_api.list_assignees(slug, function(items, err)
				if err then
					footer.notify("error", string.format("Failed to load assignees: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				items = type(items) == "table" and items or {}
				if #items == 0 then
					footer.notify("warn", "No assignees available")
					done({ changed_pr = false, message = "No assignees available" }, nil)
					return
				end

				multi_select.open({
					items = items,
					selected = {},
					key = function(item)
						return item.login
					end,
					format = function(item)
						return string.format("@%s%s", item.login, item.name and (" — " .. item.name) or "")
					end,
					prompt = string.format("Add assignees to PR #%s:", tostring(pr.id or "")),
					on_done = function(selected)
						if #selected == 0 then
							done({ changed_pr = false, message = "No assignees selected" }, nil)
							return
						end

						local args = { "pr", "edit", tostring(pr.id), "--repo", slug }
						for _, item in ipairs(selected) do
							table.insert(args, "--add-assignee")
							table.insert(args, item.login)
						end

						footer.notify("loading", "Adding assignees...")
						cli.gh(args, function(_, edit_err)
							if edit_err then
								footer.notify("error", string.format("Add assignees failed: %s", tostring(edit_err)))
								done(nil, tostring(edit_err))
								return
							end

							footer.notify("success", string.format("Added %d assignee(s)", #selected), 1200)
							done({ changed_pr = true, message = "Assignees added" }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "create_issue",
		label = "Create issue",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			if repo_slug(ctx) == "" then
				return false, "Missing repository info"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local slug = repo_slug(ctx)
			if slug == "" then
				done(nil, "Missing repository info")
				return
			end

			local issues_api = require("atlas.pulls.providers.github.api.issues")
			local create_issue_ui = require("atlas.pulls.ui.create_issue")

			create_issue_ui.open({
				repo_slug = slug,
				pickers = {
					list_labels = function(cb)
						issues_api.list_labels(slug, cb)
					end,
					list_assignees = function(cb)
						issues_api.list_assignees(slug, cb)
					end,
					list_milestones = function(cb)
						issues_api.list_milestones(slug, cb)
					end,
				},
				on_submit = function(submit_opts, submit_done)
					issues_api.create_issue({
						repo_slug = submit_opts.repo_slug,
						title = submit_opts.title,
						body = submit_opts.body,
						labels = submit_opts.labels,
						assignees = submit_opts.assignees,
						milestone = submit_opts.milestone,
					}, function(result, err)
						submit_done(result and { url = result.url, number = result.number } or nil, err)

						if not err then
							done({ changed_pr = false, message = result and result.url or "Issue created" }, nil)
						else
							done(nil, tostring(err))
						end
					end)
				end,
			})
		end,
	},
	{
		id = "notifications",
		label = "Open notifications",
		is_available = function(_)
			return true, nil
		end,
		run = function(_, done)
			local notifications_ui = require("atlas.pulls.ui.notifications")
			notifications_ui.open()
			done({ changed_pr = false, message = "Notifications opened" }, nil)
		end,
	},
	{
		id = "search",
		label = "Search repositories",
		is_available = function(_)
			return true, nil
		end,
		run = function(_, done)
			vim.ui.input({ prompt = "Search repositories: " }, function(input)
				if input == nil or vim.trim(input) == "" then
					done({ changed_pr = false, message = "Search cancelled" }, nil)
					return
				end

				local query = vim.trim(input)
				footer.notify("loading", "Searching repositories...")
				cli.gh({ "search", "repos", query, "--json", "fullName", "--limit", "20" }, function(result, err)
					if err then
						footer.notify("error", string.format("Search failed: %s", tostring(err)))
						done(nil, tostring(err))
						return
					end

					local list = {}
					for _, item in ipairs(type(result) == "table" and result or {}) do
						local full_name = tostring(item.fullName or "")
						if full_name ~= "" then
							table.insert(list, full_name)
						end
					end

					if #list == 0 then
						footer.notify("warn", "No repositories found")
						done({ changed_pr = false, message = "No repositories found" }, nil)
						return
					end

					footer.notify("info", string.format("Found %d repositories", #list), 1200)

					vim.ui.select(list, {
						prompt = "Select repository",
						kind = "atlas_github_repo_select",
					}, function(repo)
						if repo == nil then
							done({ changed_pr = false, message = "Selection cancelled" }, nil)
							return
						end

						local search_query = string.format("repo:%s is:pr", repo)
						---@type AtlasGitHubViewConfig
						local search_view = {
							name = "Search",
							key = nil,
							search = search_query,
						}

						local controller = require("atlas.pulls.ui.main.controller")
						footer.notify("success", string.format("Search view -> %s", repo))
						controller.switch_view(search_view)
						done({ changed_pr = false, message = "Search view switched" }, nil)
					end)
				end)
			end)
		end,
	},
}

---@param ctx GitHubActionContext
---@return GitHubActionDef[]
function M.available(ctx)
	local pulls_cfg = require("atlas.config").options.pulls or {}
	local custom_actions = pulls_cfg.custom_actions or {}

	local out = {}

	for _, action in ipairs(ACTIONS) do
		if action.is_available(ctx) then
			table.insert(out, action)
		end
	end

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
			label = "Checkout PR branch",
			is_available = function()
				return true, nil
			end,
			run = function(action_ctx, done)
				shared_actions.checkout(action_ctx.pr)
				done({ changed_pr = false, message = "Checkout started" }, nil)
			end,
		})
	end

	for _, item in ipairs(custom_actions) do
		if type(item) == "table" and type(item.label) == "string" and type(item.run) == "function" then
			table.insert(out, {
				id = tostring(item.id or item.label),
				label = item.label,
				is_available = function(action_ctx)
					if not has_pr(action_ctx) then
						return false, "No PR selected"
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
								logger.logerror(string.format("Custom action failed: %s", tostring(message)))
								done(nil, tostring(message or (item.label .. " failed")))
								return
							end
							footer.notify("success", tostring(message or (item.label .. " done")))
							done({ changed_pr = false, message = tostring(message or (item.label .. " done")) }, nil)
						end)
					end

					local repo_path = checkout.resolve_repo_path_for_pr(action_ctx.pr, {
						require_git = false,
						require_existing = false,
					})

					local pulls_state = require("atlas.pulls.state")
					local ok, run_err = pcall(item.run, action_ctx.pr, {
						repo_path = repo_path,
						pr = action_ctx.pr,
						user = pulls_state.current_user,
					}, custom_done)

					if not ok then
						custom_done(false, string.format("Custom action failed: %s", tostring(run_err)))
						logger.logerror(
							string.format("Custom action '%s' execution error: %s", item.label, tostring(run_err))
						)
					end
				end,
			})
		end
	end

	return out
end

---@param id GitHubActionId|string
---@return GitHubActionDef|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
