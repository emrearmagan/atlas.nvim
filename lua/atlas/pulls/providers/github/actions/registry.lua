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
		id = "toggle_approval",
		label = "Approve / Unapprove",
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
			local owner, name = slug:match("^([^/]+)/(.+)$")
			if not owner or not name then
				done(nil, "Invalid repository slug")
				return
			end

			footer.notify("loading", "Checking approval...")

			local gql = [[
				query($owner: String!, $name: String!, $number: Int!) {
					repository(owner: $owner, name: $name) {
						pullRequest(number: $number) {
							viewerLatestReview {
								databaseId
								state
							}
						}
					}
				}
			]]

			cli.gh({
				"api",
				"graphql",
				"-f",
				"owner=" .. owner,
				"-f",
				"name=" .. name,
				"-F",
				"number=" .. tostring(pr.id),
				"-f",
				"query=" .. gql,
			}, function(result, err)
				if err then
					footer.notify("error", tostring(err))
					done(nil, tostring(err))
					return
				end

				local review = ((((result or {}).data or {}).repository or {}).pullRequest or {}).viewerLatestReview
				local own_active_id = nil
				local own_active_state = nil
				if type(review) == "table" then
					local state = tostring(review.state or ""):upper()
					if state == "APPROVED" or state == "CHANGES_REQUESTED" then
						own_active_id = review.databaseId
						own_active_state = state
					end
				end

				if own_active_id ~= nil then
					local loading_msg = own_active_state == "APPROVED" and "Unapproving PR..."
						or "Dismissing changes request..."
					local success_msg = own_active_state == "APPROVED" and "PR unapproved"
						or "Changes request dismissed"
					footer.notify("loading", loading_msg)
					cli.gh({
						"api",
						"-X",
						"PUT",
						string.format(
							"repos/%s/pulls/%s/reviews/%s/dismissals",
							slug,
							tostring(pr.id),
							tostring(own_active_id)
						),
						"-f",
						"message=Dismissed by reviewer",
					}, function(_, dismiss_err)
						if dismiss_err then
							footer.notify("error", string.format("Dismiss failed: %s", tostring(dismiss_err)))
							done(nil, tostring(dismiss_err))
							return
						end
						footer.notify("success", success_msg, 1200)
						done({ changed_pr = true, message = success_msg }, nil)
					end)
				else
					footer.notify("loading", "Approving PR...")
					cli.gh({ "pr", "review", tostring(pr.id), "--repo", slug, "--approve" }, function(_, approve_err)
						if approve_err then
							footer.notify("error", string.format("Approve failed: %s", tostring(approve_err)))
							done(nil, tostring(approve_err))
							return
						end
						footer.notify("success", "PR approved", 1200)
						done({ changed_pr = true, message = "Approved" }, nil)
					end)
				end
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
		id = "edit_reviewers",
		label = "Edit reviewers",
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
			local provider = require("atlas.pulls.providers.github")
			provider.fetch_default_reviewers({
				repo_slug = slug,
				repo_root = nil,
				head = pr.source and pr.source.branch or "",
				base = pr.destination and pr.destination.branch or "",
			}, function(items, err)
				if err then
					footer.notify("error", string.format("Failed to load reviewers: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				items = items or {}
				if #items == 0 then
					footer.notify("warn", "No reviewers available")
					done({ changed_pr = false, message = "No reviewers available" }, nil)
					return
				end

				local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")
				pullrequests.get_reviewers(pr, nil, function(reviewers, r_err)
					if r_err then
						footer.notify("error", string.format("Failed to load reviewers: %s", tostring(r_err)))
						done(nil, tostring(r_err))
						return
					end

					local original_set = {}
					local original = {}
					for _, r in ipairs(reviewers or {}) do
						local login = tostring(r.nickname or r.name or "")
						if login ~= "" and not original_set[login] then
							original_set[login] = true
							table.insert(original, { provider_id = login, label = "@" .. login })
						end
					end

					multi_select.open({
						items = items,
						selected = vim.deepcopy(original),
						key = function(item)
							return item.provider_id
						end,
						format = function(item)
							return item.label
						end,
						prompt = string.format("Reviewers for PR #%s:", tostring(pr.id or "")),
						on_done = function(selected)
							local selected_set = {}
							for _, it in ipairs(selected) do
								selected_set[it.provider_id] = true
							end

							local adds, removes = {}, {}
							for login in pairs(selected_set) do
								if not original_set[login] then
									table.insert(adds, login)
								end
							end
							for login in pairs(original_set) do
								if not selected_set[login] then
									table.insert(removes, login)
								end
							end

							if #adds == 0 and #removes == 0 then
								done({ changed_pr = false, message = "No changes" }, nil)
								return
							end

							local args = { "pr", "edit", tostring(pr.id), "--repo", slug }
							for _, login in ipairs(adds) do
								table.insert(args, "--add-reviewer")
								table.insert(args, login)
							end
							for _, login in ipairs(removes) do
								table.insert(args, "--remove-reviewer")
								table.insert(args, login)
							end

							footer.notify(
								"loading",
								string.format("Updating reviewers on PR #%s...", tostring(pr.id or ""))
							)
							cli.gh(args, function(_, edit_err)
								if edit_err then
									footer.notify(
										"error",
										string.format("Update reviewers failed: %s", tostring(edit_err))
									)
									done(nil, tostring(edit_err))
									return
								end
								local msg = string.format("+%d / -%d reviewer(s)", #adds, #removes)
								footer.notify("success", msg, 1200)
								done({ changed_pr = true, message = msg }, nil)
							end)
						end,
					})
				end)
			end)
		end,
	},
	{
		id = "edit_assignees",
		label = "Edit assignees",
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
			local issues_api = require("atlas.issues.providers.github.api.issues")

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

				local raw = pr._raw or {}
				local raw_assignees = type(raw.assignees) == "table" and raw.assignees or {}
				local nodes = type(raw_assignees.nodes) == "table" and raw_assignees.nodes or {}
				local original = {}
				local original_set = {}
				for _, node in ipairs(nodes) do
					local login = type(node) == "table" and tostring(node.login or "") or ""
					if login ~= "" and not original_set[login] then
						original_set[login] = true
						table.insert(original, { account_id = login, display_name = login, email = "" })
					end
				end

				multi_select.open({
					items = items,
					selected = vim.deepcopy(original),
					key = function(item)
						return item.account_id
					end,
					format = function(item)
						return string.format(
							"@%s%s",
							item.account_id,
							item.display_name and item.display_name ~= item.account_id and (" — " .. item.display_name) or ""
						)
					end,
					prompt = string.format("Assignees for PR #%s:", tostring(pr.id or "")),
					on_done = function(selected)
						local selected_set = {}
						for _, it in ipairs(selected) do
							selected_set[it.account_id] = true
						end

						local adds, removes = {}, {}
						for login in pairs(selected_set) do
							if not original_set[login] then
								table.insert(adds, login)
							end
						end
						for login in pairs(original_set) do
							if not selected_set[login] then
								table.insert(removes, login)
							end
						end

						if #adds == 0 and #removes == 0 then
							done({ changed_pr = false, message = "No changes" }, nil)
							return
						end

						local args = { "pr", "edit", tostring(pr.id), "--repo", slug }
						for _, login in ipairs(adds) do
							table.insert(args, "--add-assignee")
							table.insert(args, login)
						end
						for _, login in ipairs(removes) do
							table.insert(args, "--remove-assignee")
							table.insert(args, login)
						end

						footer.notify(
							"loading",
							string.format("Updating assignees on PR #%s...", tostring(pr.id or ""))
						)
						cli.gh(args, function(_, edit_err)
							if edit_err then
								footer.notify("error", string.format("Update assignees failed: %s", tostring(edit_err)))
								done(nil, tostring(edit_err))
								return
							end
							local msg = string.format("+%d / -%d assignee(s)", #adds, #removes)
							footer.notify("success", msg, 1200)
							done({ changed_pr = true, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "labels",
		label = "Edit labels",
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
			local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")

			footer.notify("loading", "Loading labels...")
			pullrequests.list_labels(slug, function(labels, err)
				if err or labels == nil then
					footer.notify("error", err or "Failed to load labels")
					done(nil, err or "Failed to load labels")
					return
				end

				local items = {}
				for _, label in ipairs(labels) do
					table.insert(items, { name = label.name, color = label.color })
				end

				if #items == 0 then
					done(nil, "No labels available")
					return
				end

				local raw = pr._raw or {}
				local raw_labels = raw.labels
				if type(raw_labels) == "table" and type(raw_labels.nodes) == "table" then
					raw_labels = raw_labels.nodes
				end
				local original = {}
				local original_set = {}
				for _, label in ipairs(raw_labels or {}) do
					local name = tostring(label.name or "")
					if name ~= "" then
						table.insert(original, { name = name, color = label.color })
						original_set[name] = true
					end
				end

				multi_select.open({
					items = items,
					selected = vim.deepcopy(original),
					key = function(item)
						return item.name
					end,
					format = function(item)
						return tostring(item.name or "")
					end,
					prompt = string.format("Labels for PR #%s", tostring(pr.id or "")),
					on_done = function(selected)
						local selected_set = {}
						for _, it in ipairs(selected) do
							selected_set[it.name] = true
						end

						local adds, removes = {}, {}
						for name, _ in pairs(selected_set) do
							if not original_set[name] then
								table.insert(adds, name)
							end
						end
						for name, _ in pairs(original_set) do
							if not selected_set[name] then
								table.insert(removes, name)
							end
						end

						if #adds == 0 and #removes == 0 then
							done({ changed_pr = false, message = "No changes" }, nil)
							return
						end

						footer.notify("loading", string.format("Updating labels on #%s...", tostring(pr.id or "")))
						pullrequests.update_labels(slug, pr.id, { add = adds, remove = removes }, function(ok, set_err)
							if not ok then
								footer.notify("error", set_err or "Failed")
								done(nil, set_err or "Failed")
								return
							end
							local msg = string.format("+%d / -%d label(s)", #adds, #removes)
							footer.notify("success", msg, 1200)
							done({ changed_pr = true, message = msg }, nil)
						end)
					end,
				})
			end)
		end,
	},
	{
		id = "rerun_checks",
		label = "Re-run CI checks",
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
			local checks_api = require("atlas.pulls.providers.github.api.checks")

			footer.notify("loading", "Re-running checks...")
			checks_api.get_builds(pr, { force_refresh = true }, function(builds, err)
				if err then
					footer.notify("error", string.format("Failed to load checks: %s", tostring(err)))
					done(nil, tostring(err))
					return
				end

				checks_api.rerun_all(slug, builds or {}, function(stats)
					if stats.triggered == 0 and stats.skipped == 0 and #stats.errors == 0 then
						footer.notify("info", "No checks to re-run")
						done({ changed_pr = false, message = "No checks to re-run" }, nil)
						return
					end

					local parts = {}
					if stats.triggered > 0 then
						table.insert(parts, string.format("%d re-run", stats.triggered))
					end
					if stats.skipped > 0 then
						table.insert(parts, string.format("%d skipped", stats.skipped))
					end
					if #stats.errors > 0 then
						table.insert(parts, string.format("%d failed", #stats.errors))
					end

					local msg = table.concat(parts, ", ")
					if #stats.errors > 0 then
						footer.notify("warn", msg)
					else
						footer.notify("success", msg, 1500)
					end
					done({ changed_pr = true, message = msg }, nil)
				end)
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

			local create_issue_ui = require("atlas.issues.create.github.issue")

			create_issue_ui.open({
				repo_slug = slug,
				on_done = function(result, err)
					if err then
						done(nil, tostring(err))
						return
					end

					done({ changed_pr = false, message = result and result.url or "Issue created" }, nil)
				end,
			})
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
	{
		id = "toggle_subscription",
		label = "Toggle subscription",
		is_available = function(ctx)
			if not has_pr(ctx) or ctx.pr == nil then
				return false, "No PR selected"
			end
			local raw = type(ctx.pr._raw) == "table" and ctx.pr._raw or {}
			if tostring(raw.id or "") == "" then
				return false, "Missing PR node id"
			end
			return true, nil
		end,
		run = function(ctx, done)
			local pr = ctx.pr
			if pr == nil then
				done(nil, "No PR selected")
				return
			end
			local raw = type(pr._raw) == "table" and pr._raw or {}
			local node_id = tostring(raw.id or "")
			local next_state = pr.is_subscribed == true and "UNSUBSCRIBED" or "SUBSCRIBED"
			local gql =
				"mutation($id: ID!, $state: SubscriptionState!) { updateSubscription(input: { subscribableId: $id, state: $state }) { subscribable { ... on PullRequest { viewerSubscription } } } }"
			footer.notify("loading", pr.is_subscribed and "Unsubscribing..." or "Subscribing...")
			cli.gh(
				{ "api", "graphql", "-F", "id=" .. node_id, "-f", "state=" .. next_state, "-f", "query=" .. gql },
				function(_, err)
					if err then
						footer.notify("error", tostring(err))
						done(nil, tostring(err))
						return
					end
					pr.is_subscribed = (next_state == "SUBSCRIBED")
					footer.notify("success", pr.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
					done({ changed_pr = true, message = pr.is_subscribed and "Subscribed" or "Unsubscribed" }, nil)
				end
			)
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
