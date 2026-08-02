local M = {}

local notify = require("atlas.core.notify")

---@class AtlasCreateIssueChoice
---@field id "github"|"jira"|"gitlab"
---@field label string

---@return AtlasCreateIssueChoice[]
local function build_choices()
	local config = require("atlas.config").options or {}
	local choices = {}

	local issues_providers = (config.issues and config.issues.providers) or {}
	if issues_providers.github then
		local gh = require("atlas.issues.providers.github")
		if type(gh.create_issue) == "function" then
			table.insert(choices, { id = "github", label = "GitHub" })
		end
	end

	if issues_providers.gitlab then
		local gl = require("atlas.issues.providers.gitlab")
		if type(gl.create_issue) == "function" then
			table.insert(choices, { id = "gitlab", label = "GitLab" })
		end
	end

	if issues_providers.jira then
		table.insert(choices, { id = "jira", label = "Jira" })
	end

	return choices
end

---@param choice AtlasCreateIssueChoice
local function dispatch(choice)
	if choice.id == "jira" then
		local actions = require("atlas.issues.providers.jira.actions")
		actions.run("create_issue", {}, function(_, err)
			if err then
				notify.error("Jira create issue failed: " .. tostring(err))
			end
		end)
		return
	end

	local git_branch = require("atlas.core.git")
	local root, root_err = git_branch.repo_root(nil)
	if not root then
		notify.error(root_err or "Not in a git repository")
		return
	end

	local remote_url, remote_err = git_branch.remote_url(root, "origin")
	if not remote_url then
		notify.error(remote_err or "No origin remote configured")
		return
	end

	local info, parse_err = git_branch.parse_remote_url(remote_url)
	if not info then
		notify.error(parse_err or "Could not parse remote URL")
		return
	end

	if info.provider ~= choice.id then
		notify.error(
			string.format(
				"Current repo is on %s but you picked %s; switch into the right clone first",
				info.provider,
				choice.id
			)
		)
		return
	end

	if choice.id == "github" then
		require("atlas.issues.create.github.issue").open({ repo_slug = info.slug })
		return
	end

	if choice.id == "gitlab" then
		require("atlas.issues.create.gitlab.issue").open({ project_path = info.slug })
		return
	end

	notify.error("Unsupported issue provider: " .. choice.id)
end

function M.start()
	local choices = build_choices()

	if #choices == 0 then
		notify.error("No issue-capable provider is configured")
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
