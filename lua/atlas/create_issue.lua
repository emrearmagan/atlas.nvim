--- for `:AtlasCreateIssue`.
local M = {}

local function notify(level, msg)
	vim.notify("[Atlas] " .. tostring(msg), level)
end

local function notify_error(msg)
	notify(vim.log.levels.ERROR, msg)
end

---@class AtlasCreateIssueChoice
---@field id "github"|"bitbucket"|"jira"
---@field label string
---@field kind "pulls"|"jira"

---@return AtlasCreateIssueChoice[]
local function build_choices()
	local config = require("atlas.config").options or {}
	local choices = {}

	local pulls_providers = (config.pulls and config.pulls.providers) or {}
	if pulls_providers.github then
		local gh = require("atlas.pulls.providers.github")
		if type(gh.create_issue) == "function" then
			table.insert(choices, { id = "github", label = "GitHub", kind = "pulls" })
		end
	end
	if pulls_providers.bitbucket then
		local bb = require("atlas.pulls.providers.bitbucket")
		if type(bb.create_issue) == "function" then
			table.insert(choices, { id = "bitbucket", label = "Bitbucket", kind = "pulls" })
		end
	end

	local issues_providers = (config.issues and config.issues.providers) or {}
	if issues_providers.jira then
		table.insert(choices, { id = "jira", label = "Jira", kind = "jira" })
	end

	return choices
end

---@param provider PullsProvider
---@param repo_slug string
local function open_pulls_editor(provider, repo_slug)
	local create_issue_ui = require("atlas.pulls.ui.create_issue")

	local pickers = {}
	if provider.id == "github" then
		local issues_api = require("atlas.pulls.providers.github.api.issues")
		pickers = {
			list_labels = function(cb)
				issues_api.list_labels(repo_slug, cb)
			end,
			list_assignees = function(cb)
				issues_api.list_assignees(repo_slug, cb)
			end,
			list_milestones = function(cb)
				issues_api.list_milestones(repo_slug, cb)
			end,
		}
	end

	create_issue_ui.open({
		repo_slug = repo_slug,
		pickers = pickers,
		on_submit = function(submit_opts, submit_done)
			provider.create_issue({
				repo_slug = submit_opts.repo_slug,
				title = submit_opts.title,
				body = submit_opts.body,
				labels = submit_opts.labels,
				assignees = submit_opts.assignees,
				milestone = submit_opts.milestone,
			}, function(result, err)
				submit_done(result and { url = result.url, number = result.id } or nil, err)
			end)
		end,
	})
end

---@param choice AtlasCreateIssueChoice
local function dispatch(choice)
	if choice.kind == "jira" then
		local actions = require("atlas.issues.providers.jira.actions")
		actions.run("create_issue", {}, function(_, err)
			if err then
				notify_error("Jira create issue failed: " .. tostring(err))
			end
		end)
		return
	end

	local git_branch = require("atlas.core.git.branch")
	local root, root_err = git_branch.repo_root(nil)
	if not root then
		notify_error(root_err or "Not in a git repository")
		return
	end

	local remote_url, remote_err = git_branch.remote_url(root, "origin")
	if not remote_url then
		notify_error(remote_err or "No origin remote configured")
		return
	end

	local info, parse_err = git_branch.parse_remote_url(remote_url)
	if not info then
		notify_error(parse_err or "Could not parse remote URL")
		return
	end

	if info.provider ~= choice.id then
		notify_error(
			string.format(
				"Current repo is on %s but you picked %s; switch into the right clone first",
				info.provider,
				choice.id
			)
		)
		return
	end

	local provider
	if choice.id == "github" then
		provider = require("atlas.pulls.providers.github")
	elseif choice.id == "bitbucket" then
		provider = require("atlas.pulls.providers.bitbucket")
	end

	if type(provider) ~= "table" or type(provider.create_issue) ~= "function" then
		notify_error("Provider unavailable or does not support issue creation: " .. choice.id)
		return
	end

	open_pulls_editor(provider, info.slug)
end

function M.start()
	local choices = build_choices()

	if #choices == 0 then
		notify_error("No issue-capable provider is configured")
		return
	end

	if #choices == 1 then
		dispatch(choices[1])
		return
	end

	local labels = {}
	for _, c in ipairs(choices) do
		table.insert(labels, c.label)
	end

	vim.ui.select(labels, { prompt = "Create issue with:" }, function(_, idx)
		if idx == nil then
			return
		end
		dispatch(choices[idx])
	end)
end

return M
