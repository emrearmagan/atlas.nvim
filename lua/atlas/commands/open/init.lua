local M = {}

local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.picker")
local providers = require("atlas.providers")
local resolver = require("atlas.providers.resolve")
local request_id = 0

---@param domain "pulls"|"issues"
---@return PullsProvider|IssuesProvider|nil
local function current_provider(domain)
	local module = domain == "pulls" and "atlas.pulls.state" or "atlas.issues.state"
	return require(module).provider
end

local function ensure_detail_open()
	local layout = require("atlas.ui.layout")
	if layout.win_id("detail") == nil then
		layout.toggle_detail()
	end
end

---@param target AtlasTarget
---@return PullsProvider|IssuesProvider|nil
local function activate(target)
	local other_panel = target.domain == "pulls" and "atlas.issues.ui.panel" or "atlas.pulls.ui.panel"
	local ok, panel = pcall(require, other_panel)
	if ok and type(panel.is_open) == "function" and panel.is_open() then
		panel.close()
	end

	local implementation = assert(providers.load(target.provider, target.domain))
	require("atlas").open(target.domain, target.provider, { initial_view = implementation.search_view(target) })
	local provider = current_provider(target.domain)
	if provider == nil then
		notify.error("Failed to load provider: " .. target.provider)
	end
	return provider
end

---@param target AtlasTarget
---@return string, string, string
local function repo_identity(target)
	local owner = tostring(target.owner or target.workspace or "")
	local repo = tostring(target.repo or "")
	local full_name = target.project_path or (owner ~= "" and owner .. "/" .. repo or repo)
	return owner, repo, full_name
end

---@param target AtlasTarget
---@return PullsRepo
local function repo_from_target(target)
	local owner, repo, full_name = repo_identity(target)
	return {
		id = full_name,
		name = full_name,
		owner = owner ~= "" and owner or nil,
		repo_name = repo ~= "" and repo or nil,
		html_url = target.url,
	}
end

---@param target AtlasTarget
---@param method string
---@param argument any
---@param label string
---@param on_success fun(result: any)
---@param on_error? fun(err: string)
local function fetch_and_open(target, method, argument, label, on_success, on_error)
	local current_request = request_id
	local provider = providers.load(target.provider, target.domain)
	if provider == nil then
		if on_error then
			on_error("provider unavailable")
		end
		return
	end

	local core = provider.capabilities.core
	local fetch = core[method]
	if type(fetch) ~= "function" then
		local message = label .. " fetch is not supported for " .. target.provider
		if on_error then
			on_error(message)
		else
			notify.error(message)
		end
		return
	end

	fetch(argument, { force_load = true }, function(result, err)
		if current_request ~= request_id then
			return
		end
		if err or result == nil then
			local message = tostring(err or "empty response")
			if on_error then
				on_error(message)
			else
				notify.error("Failed to open " .. label:lower() .. ": " .. message)
			end
			return
		end
		if activate(target) == nil then
			if on_error then
				on_error("provider unavailable")
			end
			return
		end
		notify.info(string.format("Opening %s %s...", provider.name or target.provider, label:lower()))
		ensure_detail_open()
		on_success(result)
	end)
end

---@param target AtlasTarget
---@param on_error? fun(err: string)
local function open_issue(target, on_error)
	local key = assert(providers.load(target.provider, "issues")).issue_key(target)
	if key == nil then
		if on_error then
			on_error("could not determine issue key")
		else
			notify.error("Could not determine issue key")
		end
		return
	end
	fetch_and_open(target, "fetch_issue", key, "Issue " .. key, function(issue)
		require("atlas.issues.ui.panel").on_select(issue, { force_refresh = true })
	end, on_error)
end

---@param target AtlasTarget
---@param on_error? fun(err: string)
local function open_pr(target, on_error)
	fetch_and_open(
		target,
		"fetch_pullrequest",
		resolver.pull_request_ref(target),
		"Pull request #" .. tostring(target.number),
		function(pr)
			require("atlas.pulls.ui.panel.state").current_panel = "pr"
			require("atlas.pulls.ui.panel").on_select(pr, repo_from_target(target), { force_refresh = true })
		end,
		on_error
	)
end

---@param number integer
---@param info AtlasGitRemoteInfo
---@param on_error? fun(err: string)
local function open_number_for_repo(number, info, on_error)
	local pr_target = providers.domain(info.provider, "pulls") and resolver.target(info, "pulls", "pr", number)
	local issue_target = providers.domain(info.provider, "issues") and resolver.target(info, "issues", "issue", number)
	local has_pulls = pr_target and resolver.configured(pr_target)
	local has_issues = issue_target and resolver.configured(issue_target)

	if has_pulls then
		---@cast pr_target AtlasTarget
		open_pr(pr_target, has_issues and function()
			---@cast issue_target AtlasTarget
			open_issue(issue_target, on_error)
		end or on_error)
	elseif has_issues then
		---@cast issue_target AtlasTarget
		open_issue(issue_target, on_error)
	elseif on_error then
		on_error("provider not configured")
	else
		notify.error("Provider not configured for repository: " .. info.provider)
	end
end

---@param choices AtlasGitRemoteInfo[]
---@param prompt string
---@param on_choice fun(choice: AtlasGitRemoteInfo)
local function choose_repository(choices, prompt, on_choice)
	if #choices == 1 then
		on_choice(choices[1])
		return
	end
	local current_request = request_id
	picker.select({
		title = prompt,
		items = choices,
		format_item = function(item)
			return string.format("%s  %s", item.provider, item.slug)
		end,
		on_select = function(choice)
			if choice and current_request == request_id then
				on_choice(choice)
			end
		end,
	})
end

---@param choices AtlasGitRemoteInfo[]
---@param number integer
local function try_repositories(choices, number)
	local current_request = request_id
	local function try(index)
		if current_request ~= request_id then
			return
		end
		local choice = choices[index]
		if choice == nil then
			notify.error("Reference not found in any configured provider")
			return
		end
		open_number_for_repo(number, choice, function()
			try(index + 1)
		end)
	end
	try(1)
end

---@param number integer
---@param repo_slug string|nil
local function open_number(number, repo_slug)
	local info = repo_slug == nil and git.local_repository() or nil
	if info then
		open_number_for_repo(number, info)
		return
	end

	local choices = resolver.configured_repositories(repo_slug)
	if #choices == 0 then
		notify.error("Could not determine a configured repository; use owner/repo#number or a full URL")
		return
	end
	if repo_slug then
		try_repositories(choices, number)
		return
	end
	choose_repository(choices, "Select repository", function(choice)
		open_number_for_repo(number, choice)
	end)
end

local openers = {
	repo = activate,
	pr = open_pr,
	issue = open_issue,
}

---@param target AtlasTarget
local function open_target(target)
	if not resolver.configured(target) then
		notify.error(string.format("Provider not configured for %s: %s", target.domain, target.provider))
		return
	end

	local opener = openers[target.entity]
	if opener == nil then
		notify.error("Unsupported Atlas URL entity: " .. tostring(target.entity))
		return
	end
	opener(target)
end

---@param value string
function M.open(value)
	request_id = request_id + 1
	if vim.trim(value) == "." then
		local info = git.local_repository()
		if info == nil then
			notify.error("No supported Git repository found")
			return
		end
		open_target(resolver.target(info, "pulls", "repo", nil))
		return
	end

	local result, err = resolver.resolve(value)
	if result == nil then
		notify.error(err or "Unsupported Atlas URL")
		return
	end

	notify.info("Resolving " .. tostring(value) .. "...")
	if result.domain then
		---@cast result AtlasTarget
		open_target(result)
	else
		---@cast result AtlasOpenReference
		open_number(result.number, result.repo_slug)
	end
end

return M
