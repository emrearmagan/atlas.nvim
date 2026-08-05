local M = {}

local notify = require("atlas.core.notify")
local providers = require("atlas.providers")

---@class AtlasCreateIssueChoice
---@field label string
---@field provider IssuesProvider

---@return AtlasCreateIssueChoice[]
local function build_choices()
	local choices = {}
	for _, provider_config in ipairs(providers.configured("issues")) do
		local provider = providers.load(provider_config.id, "issues")
		if provider and provider.capabilities.create_issue then
			table.insert(choices, { label = provider_config.name, provider = provider })
		end
	end

	return choices
end

---@param provider_id string
---@param open fun(opts: table)
---@param repo_field string
function M.from_repository(provider_id, open, repo_field)
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

	if info.provider ~= provider_id then
		notify.error(
			string.format(
				"Current repo is on %s but you picked %s; switch into the right clone first",
				info.provider,
				provider_id
			)
		)
		return
	end

	open({ [repo_field] = info.slug })
end

function M.start()
	local choices = build_choices()

	if #choices == 0 then
		notify.error("No issue-capable provider is configured")
		return
	end

	if #choices == 1 then
		choices[1].provider.capabilities.create_issue()
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
		choices[idx].provider.capabilities.create_issue()
	end)
end

return M
