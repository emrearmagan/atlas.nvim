local M = {}

local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local state = require("atlas.pulls.state")
local query = require("atlas.providers.azure.query")
local repositories = require("atlas.pulls.providers.azure.api.repositories")
local pullrequests = require("atlas.pulls.providers.azure.api.pullrequests")

---@param title string
---@param on_select fun(repo: { name: string, project: { name: string } })
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function select_repository(title, on_select, done)
	notify.loading("Loading repositories...")
	repositories.fetch_repositories(function(items, err)
		if err then
			notify.error(err)
			done(nil, err)
			return
		end
		---@cast items table[]
		notify.clear()
		picker.select({
			title = title,
			items = items,
			format_item = function(repo)
				return repo.project.name .. "/" .. repo.name
			end,
			on_select = function(repo)
				if repo then
					on_select(repo)
				else
					done(nil, nil)
				end
			end,
		})
	end)
end

---@param pr PullRequest
---@return string
local function pull_label(pr)
	return string.format("#%s - %s", pr.id, pr.title)
end

---@param pr PullRequest
---@param on_done fun(preview: AtlasPickerPreview)
---@return { cancel: fun() }|nil
local function preview(pr, on_done)
	return pullrequests.fetch_pullrequest(pr, nil, function(details, err)
		if not details then
			on_done({ title = pull_label(pr), lines = { err or "Failed to load pull request" } })
			return
		end
		local lines = {
			"**Status:** " .. pr.state,
			"**Author:** " .. pr.author.name,
			string.format("**Branches:** %s -> %s", pr.source.branch, pr.destination.branch),
		}
		local reviewers = vim.tbl_map(function(user)
			return user.name
		end, pr.reviewers or {})
		local labels = vim.tbl_map(function(label)
			return label.name
		end, details.labels or {})
		if #reviewers > 0 then
			table.insert(lines, "**Reviewers:** " .. table.concat(reviewers, ", "))
		end
		if #labels > 0 then
			table.insert(lines, "**Tags:** " .. table.concat(labels, ", "))
		end
		vim.list_extend(lines, { "", "## Description", "" })
		local description = vim.trim(details.description)
		vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
		on_done({ title = pull_label(pr), lines = lines })
	end)
end

---@param context AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
function M.search(context, done)
	select_repository("Search Pull Requests - Repository", function(repo)
		notify.loading("Loading pull requests...")
		pullrequests.fetch_pullrequests({
			name = "Search",
			project = repo.project.name,
			repository = repo.name,
			scope = "all",
		}, { pagelen = 100, state = "all" }, function(page, err)
			if err then
				notify.error(err)
				done(nil, err)
				return
			end
			notify.clear()
			picker.select_with_preview({
				title = string.format("Search %s/%s Pull Requests", repo.project.name, repo.name)
					.. (page.next_cursor and " (first 100)" or ""),
				items = page.items,
				key = function(pr)
					return tostring(pr.id)
				end,
				format_item = pull_label,
				preview_item = preview,
				on_select = function(pr)
					if pr then
						require("atlas.pulls.ui.detail").open(pr, { provider = context.provider })
					end
					done(nil, nil)
				end,
			})
		end)
	end, done)
end

---@param context AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
function M.open_view(context, done)
	local current = state.provider == context.provider and state.search_view() or nil
	local view = current
		or {
			name = "Search",
			project = context.pr and context.pr.workspace,
			repository = context.pr and context.pr.repo,
			scope = "all",
		}
	vim.ui.input({ prompt = "Search: ", default = query.query(view) }, function(input)
		if input == nil or vim.trim(input) == "" then
			done(nil, nil)
			return
		end
		local filters, err = query.parse(input)
		if not filters then
			notify.warn(err)
			done(nil, err)
			return
		end
		require("atlas").open("pulls", "azure", { initial_view = filters })
		done(nil, nil)
	end)
end

---@param _ AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
function M.edit(_, done)
	local view = state.search_view()
	if not view then
		done(nil, nil)
		return
	end
	---@cast view AtlasAzurePullsViewConfig
	vim.ui.input({ prompt = "Search: ", default = query.query(view) }, function(input)
		if input == nil or vim.trim(input) == "" then
			done(nil, nil)
			return
		end
		local ok, err = query.apply(view, input)
		if not ok then
			notify.warn(err)
			done(nil, err)
			return
		end
		require("atlas.pulls.ui.dashboard.controller").refresh_view()
		done(nil, nil)
	end)
end

---@param _ AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
function M.open_repo(_, done)
	select_repository("Open Repo", function(repo)
		require("atlas").open("pulls", "azure", {
			initial_view = {
				name = "Search",
				layout = "compact",
				project = repo.project.name,
				repository = repo.name,
				scope = "all",
			},
		})
		done(nil, nil)
	end, done)
end

return M
