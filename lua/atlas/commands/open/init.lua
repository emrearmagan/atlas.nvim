local M = {}

local parser = require("atlas.commands.open.parser")
local resolver = require("atlas.commands.open.resolver")
local request_id = 0

---@param message string
---@param level integer|nil
local function notify(message, level)
	vim.notify("[Atlas] " .. message, level or vim.log.levels.INFO)
end

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

---@param target AtlasOpenTarget
---@return AtlasPullsViewConfig|IssuesViewConfig
local function search_view(target)
	local view = { name = "Search", layout = "compact" }
	if target.provider == "jira" then
		view.jql = "key = " .. target.issue_key
	elseif target.provider == "github" then
		view.search = string.format(
			"repo:%s/%s %s %s",
			target.owner,
			target.repo,
			target.number and tostring(target.number) or "",
			target.domain == "issues" and "is:issue" or "is:pr"
		)
	elseif target.provider == "gitlab" then
		view.project = target.project_path
		view.scope = "all"
		view.state = target.domain == "issues" and "all" or nil
	elseif target.provider == "bitbucket" then
		view.repos = { { workspace = target.workspace, repo = target.repo } }
	end
	return view
end

---@param target AtlasOpenTarget
---@return PullsProvider|IssuesProvider|nil
local function activate(target)
	local other_panel = target.domain == "pulls" and "atlas.issues.ui.panel" or "atlas.pulls.ui.panel"
	local ok, panel = pcall(require, other_panel)
	if ok and type(panel.is_open) == "function" and panel.is_open() then
		panel.close()
	end

	require("atlas").open(target.domain, target.provider, {
		initial_view = search_view(target),
	})
	local provider = current_provider(target.domain)
	if provider == nil then
		notify("Failed to load provider: " .. target.provider, vim.log.levels.ERROR)
	end
	return provider
end

---@param target AtlasOpenTarget
---@return string, string, string
local function repo_identity(target)
	local owner = tostring(target.owner or target.workspace or "")
	local repo = tostring(target.repo or "")
	local full_name = target.project_path or (owner ~= "" and owner .. "/" .. repo or repo)
	return owner, repo, full_name
end

---@param target AtlasOpenTarget
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

---@param target AtlasOpenTarget
---@return PullRequest
local function pr_from_target(target)
	local owner, repo, full_name = repo_identity(target)
	local number = assert(target.number, "PR target missing number")
	return {
		id = number,
		title = "#" .. tostring(number),
		description = "",
		state = "open",
		author = { name = "", id = "", username = "" },
		source = { branch = "", commit_hash = "" },
		destination = { branch = "", commit_hash = "" },
		comments_count = 0,
		tasks_count = 0,
		created_on = "",
		updated_on = "",
		link = { html = target.url },
		provider = target.provider,
		workspace = owner,
		repo = repo,
		repo_full_name = full_name,
		_raw = target.provider == "gitlab" and { project_path = target.project_path, iid = number } or nil,
	}
end

---@param target AtlasOpenTarget
---@return string|nil
local function issue_key(target)
	if target.issue_key then
		return target.issue_key
	end
	if target.provider == "github" and target.owner and target.repo and target.number then
		return string.format("%s/%s#%d", target.owner, target.repo, target.number)
	end
	if target.provider == "gitlab" and target.project_path and target.number then
		return string.format("%s#%d", target.project_path, target.number)
	end
	return nil
end

---@param target AtlasOpenTarget
local function open_repo(target)
	if activate(target) == nil then
		return
	end
	ensure_detail_open()
	require("atlas.pulls.ui.panel.state").current_panel = "repo"
	require("atlas.pulls.ui.panel").on_select(nil, repo_from_target(target), { force_refresh = true })
end

---@param target AtlasOpenTarget
---@param method string
---@param argument any
---@param label string
---@param on_success fun(result: any)
---@param on_error? fun(err: string)
local function fetch_and_open(target, method, argument, label, on_success, on_error)
	local current_request = request_id
	local provider = resolver.load_provider(target)
	if provider == nil then
		if on_error then
			on_error("provider unavailable")
		end
		return
	end

	local fetch = provider[method]
	if type(fetch) ~= "function" then
		local message = label .. " fetch is not supported for " .. target.provider
		if on_error then
			on_error(message)
		else
			notify(message, vim.log.levels.ERROR)
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
				notify("Failed to open " .. label:lower() .. ": " .. message, vim.log.levels.ERROR)
			end
			return
		end
		if activate(target) == nil then
			if on_error then
				on_error("provider unavailable")
			end
			return
		end
		notify(string.format("Opening %s %s...", provider.name or target.provider, label:lower()))
		ensure_detail_open()
		on_success(result)
	end)
end

---@param target AtlasOpenTarget
---@param on_error? fun(err: string)
local function open_issue(target, on_error)
	local key = issue_key(target)
	if key == nil then
		if on_error then
			on_error("could not determine issue key")
		else
			notify("Could not determine issue key", vim.log.levels.ERROR)
		end
		return
	end
	fetch_and_open(target, "fetch_issue", key, "Issue " .. key, function(issue)
		require("atlas.issues.ui.panel").on_select(issue, { force_refresh = true })
	end, on_error)
end

---@param target AtlasOpenTarget
---@param on_error? fun(err: string)
local function open_pr(target, on_error)
	fetch_and_open(
		target,
		"fetch_pullrequest",
		pr_from_target(target),
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
	local pr_target = resolver.target(info, "pulls", "pr", number)
	local issue_target = resolver.target(info, "issues", "issue", number)
	local has_pulls = resolver.provider_configured(pr_target)
	local has_issues = info.provider ~= "bitbucket" and resolver.provider_configured(issue_target)

	if has_pulls then
		open_pr(pr_target, has_issues and function()
			open_issue(issue_target, on_error)
		end or on_error)
	elseif has_issues then
		open_issue(issue_target, on_error)
	elseif on_error then
		on_error("provider not configured")
	else
		notify("Provider not configured for repository: " .. info.provider, vim.log.levels.ERROR)
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
	vim.ui.select(choices, {
		prompt = prompt,
		format_item = function(item)
			return string.format("%s · %s", item.provider, item.slug)
		end,
	}, function(choice)
		if choice and current_request == request_id then
			on_choice(choice)
		end
	end)
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
			notify("Reference not found in any configured provider", vim.log.levels.ERROR)
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
	local info = repo_slug == nil and resolver.local_repository() or nil
	if info then
		open_number_for_repo(number, info)
		return
	end

	local choices = resolver.configured_repositories(repo_slug)
	if #choices == 0 then
		notify("Could not determine a configured repository; use owner/repo#number or a full URL", vim.log.levels.ERROR)
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
	repo = open_repo,
	pr = open_pr,
	issue = open_issue,
}

---@param target AtlasOpenTarget
local function open_target(target)
	if not resolver.provider_configured(target) then
		notify(
			string.format("Provider not configured for %s: %s", target.domain, target.provider),
			vim.log.levels.ERROR
		)
		return
	end

	local opener = openers[target.entity]
	if opener == nil then
		notify("Unsupported Atlas URL entity: " .. tostring(target.entity), vim.log.levels.ERROR)
		return
	end
	opener(target)
end

---@param url string
function M.open(url)
	request_id = request_id + 1
	local reference = parser.parse_reference(url)
	if reference then
		notify("Resolving " .. tostring(url) .. "...")
		if reference.issue_key then
			local target = {
				provider = "jira",
				domain = "issues",
				entity = "issue",
				host = "",
				issue_key = reference.issue_key,
			}
			local base = resolver.base_url(target)
			target.host = base:match("^https?://([^/]+)") or ""
			target.url = base .. "/browse/" .. reference.issue_key
			open_target(target)
		else
			open_number(assert(reference.number), reference.repo_slug)
		end
		return
	end

	local target, err = parser.parse(url)
	if target == nil then
		notify(err or "Unsupported Atlas URL", vim.log.levels.ERROR)
		return
	end
	notify("Resolving " .. tostring(url) .. "...")
	open_target(target)
end

return M
