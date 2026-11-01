-- Inspired by:
-- https://github.com/mjveilleux/pr-description.nvim
-- https://github.com/RemoteRabbit/pr-description.nvim

local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local requests = require("atlas.core.requests")

local DEFAULT_PR_TEMPLATE = ".github/pull_request_template.md"

local URL_PATHS = {
	azure = { commit = "/commit/" },
	github = { issue = "/issues/", commit = "/commit/" },
	gitlab = { issue = "/-/issues/", commit = "/-/commit/" },
	bitbucket = { issue = "/issues/", commit = "/commits/" },
	jira = { issue = "/browse/" },
}

local COMMIT_CATEGORIES = {
	feat = "features",
	feature = "features",
	fix = "fixes",
	bugfix = "fixes",
	perf = "performance",
	doc = "documentation",
	docs = "documentation",
	refactor = "refactoring",
	test = "tests",
	tests = "tests",
	style = "style",
	format = "style",
	chore = "maintenance",
	ci = "operations",
	build = "operations",
	ops = "operations",
	revert = "reverts",
	wip = "wip",
}

local SECTIONS = {
	{ key = "breaking", title = "Breaking changes" },
	{ key = "features", title = "Features" },
	{ key = "fixes", title = "Fixes" },
	{ key = "performance", title = "Performance" },
	{ key = "documentation", title = "Documentation" },
	{ key = "refactoring", title = "Refactoring" },
	{ key = "tests", title = "Tests" },
	{ key = "style", title = "Style" },
	{ key = "maintenance", title = "Maintenance" },
	{ key = "operations", title = "Operations" },
	{ key = "reverts", title = "Reverts" },
	{ key = "wip", title = "Work in progress" },
	{ key = "other", title = "Other changes" },
}

---@class PullsCreateDescription
---@field title string
---@field body string
---@field commits { hash: string, subject: string }[]
---@field diffstat string[]

---@class PullsCreateDescriptionLinks
---@field provider AtlasPullsProviderId|"unknown"|nil
---@field repo_url string|nil
---@field jira_url string|nil
---@field urls { issue: string|nil, commit: string|nil }

---@param root string
---@param repo_slug string
---@return string|nil
local function read_template(root, repo_slug)
	local pulls = config.options.pulls or {}
	local repo_config = pulls.repo_config or {}
	local settings = repo_config.settings or {}
	local repo_settings = settings[repo_slug] or {}
	local template_path = vim.trim(repo_settings.pr_template or DEFAULT_PR_TEMPLATE)
	if template_path == "" then
		return nil
	end

	local path = root .. "/" .. template_path
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil
	end
	local template = vim.trim(table.concat(lines, "\n"))
	return template ~= "" and template or nil
end

---@param lines string[]
---@param diffstat string[]
local function add_diffstat(lines, diffstat)
	if #diffstat == 0 then
		return
	end
	table.insert(lines, "**Diffstat**")
	table.insert(lines, "")
	table.insert(lines, "```text")
	vim.list_extend(lines, diffstat)
	table.insert(lines, "```")
end

---@return string|nil
local function jira_url()
	local jira = config.provider_options("jira")
	if jira == nil then
		return nil
	end
	local base_url = vim.trim(jira.base_url or ""):gsub("/+$", "")
	if base_url == "" then
		return nil
	end
	return base_url .. URL_PATHS.jira.issue:gsub("/+$", "")
end

---@param remote AtlasTarget|nil
---@return PullsCreateDescriptionLinks
local function links(remote)
	return {
		provider = remote and remote.provider or nil,
		repo_url = remote and remote.url or nil,
		jira_url = jira_url(),
		urls = (remote and URL_PATHS[remote.provider]) or {},
	}
end

---@param text string
---@param context PullsCreateDescriptionLinks
---@return string
local function add_links(text, context)
	if context.jira_url then
		text = text:gsub("%[?([A-Z][A-Z0-9]+%-%d+)%]?", function(key)
			return string.format("[%s](%s/%s)", key, context.jira_url, key)
		end)
	end

	if context.repo_url and context.urls.issue then
		local issue_path = context.urls.issue
		text = text:gsub("%[?#(%d+)%]?", function(number)
			return string.format("[#%s](%s%s%s)", number, context.repo_url, issue_path, number)
		end)
	end

	return text
end

---@param hash string
---@param context PullsCreateDescriptionLinks
---@return string
local function commit_link(hash, context)
	if context.repo_url == nil then
		return "`" .. hash .. "`"
	end
	local path = context.urls.commit or "/commit/"
	return string.format("[`%s`](%s%s%s)", hash, context.repo_url, path, hash)
end

---@param commits { hash: string, subject: string }[]
---@param context PullsCreateDescriptionLinks
---@param options AtlasPullsDescriptionConfig
---@return string[]
local function plain_commits(commits, context, options)
	return vim.tbl_map(function(commit)
		local hash = options.include_commit_hashes and (commit_link(commit.hash, context) .. " ") or ""
		return "- " .. hash .. add_links(commit.subject, context)
	end, commits)
end

---@param context PullsCreateDescriptionLinks
---@param head string
---@param commits { hash: string, subject: string }[]
---@return string[]
local function related(context, head, commits)
	local items = {}
	local seen = {}
	local texts = { head }
	for _, commit in ipairs(commits) do
		table.insert(texts, commit.subject)
	end

	local function add(label, url)
		if seen[label] then
			return
		end
		seen[label] = true
		table.insert(items, string.format("- [%s](%s)", label, url))
	end

	for _, text in ipairs(texts) do
		if context.jira_url then
			for key in text:gmatch("[A-Z][A-Z0-9]+%-%d+") do
				add(key, context.jira_url .. "/" .. key)
			end
		end
		if context.repo_url then
			local issue_path = context.urls.issue or "/issues/"
			for number in text:gmatch("#(%d+)") do
				add("#" .. number, context.repo_url .. issue_path .. number)
			end
		end
	end

	return items
end

---@param subject string
---@return string category
---@return string description
---@return boolean conventional
local function parse_commit(subject)
	local issue_key, candidate = subject:match("^%[([A-Z][A-Z0-9]+%-%d+)%]%s*(.+)$")
	candidate = candidate or subject

	local kind, scope, breaking, description = candidate:match("^([%w-]+)%(([^)]+)%)(!?):%s*(.+)$")
	if kind == nil then
		kind, breaking, description = candidate:match("^([%w-]+)(!?):%s*(.+)$")
	end
	if kind == nil then
		return "other", subject, false
	end
	local prefix = issue_key and ("[" .. issue_key .. "] ") or ""
	if scope then
		if scope:match("^[A-Z][A-Z0-9]+%-%d+$") then
			prefix = prefix .. "[" .. scope .. "] "
		else
			prefix = prefix .. "(" .. scope .. ") "
		end
	end
	description = prefix .. description
	if breaking == "!" then
		return "breaking", description, true
	end
	return COMMIT_CATEGORIES[kind:lower()] or "other", description, true
end

---@param context PullsCreateDescriptionLinks
---@param head string
---@param commits { hash: string, subject: string }[]
---@param diffstat string[]
---@return string
local function generate(context, head, commits, diffstat)
	local options = config.options.pulls.description
	---@cast options AtlasPullsDescriptionConfig
	local categories = {}
	local conventional = false
	for _, commit in ipairs(commits) do
		local category, description, parsed = parse_commit(commit.subject)
		conventional = conventional or parsed
		categories[category] = categories[category] or {}
		local hash = options.include_commit_hashes and (" (" .. commit_link(commit.hash, context) .. ")") or ""
		table.insert(categories[category], "- " .. add_links(description, context) .. hash)
	end

	local lines = {}
	if options.include_summary and #commits > 0 then
		vim.list_extend(lines, { "## Summary", "", "<!-- TODO: Describe the change and why it is needed. -->", "" })
	end
	if conventional then
		vim.list_extend(lines, { "## Changes", "" })
		local used_sections = {}
		for _, section in ipairs(SECTIONS) do
			if categories[section.key] then
				table.insert(used_sections, section)
			end
		end
		for _, section in ipairs(used_sections) do
			if #used_sections > 1 then
				table.insert(lines, "**" .. section.title .. "**")
			end
			vim.list_extend(lines, categories[section.key])
			table.insert(lines, "")
		end
	else
		vim.list_extend(lines, plain_commits(commits, context, options))
		table.insert(lines, "")
	end

	if options.include_related then
		local references = related(context, head, commits)
		if #references > 0 then
			table.insert(lines, "## Related")
			table.insert(lines, "")
			vim.list_extend(lines, references)
			table.insert(lines, "")
		end
	end

	if options.include_diffstat then
		add_diffstat(lines, diffstat)
	end

	return vim.trim(table.concat(lines, "\n"))
end

---@param root string
---@param repo_slug string
---@param base string
---@param head string
---@param repository AtlasTarget
---@param on_done fun(description: PullsCreateDescription|nil, err: string|nil)
---@return AtlasRequestScope
function M.build(root, repo_slug, base, head, repository, on_done)
	local scope = requests.new()
	scope.run(function(done)
		return git.diff_revisions(root, base, head, done)
	end, function(base_revision, head_revision, err)
		if not base_revision or not head_revision then
			on_done(nil, err)
			return
		end
		local template = read_template(root, repo_slug)
		local loaders = {
			commits = function(done)
				return git.commits_for_range(root, base_revision .. ".." .. head_revision, done)
			end,
			diffstat = function(done)
				return git.diff_stat(root, base_revision, head_revision, done)
			end,
		}
		scope.all(loaders, function(values)
			local commits, diffstat = values.commits or {}, values.diffstat or {}
			local latest_commit = commits[#commits]
			local body = template
			if body == nil then
				local context = links(repository)
				body = generate(context, head, commits, diffstat)
			end
			on_done({
				title = latest_commit and latest_commit.subject or "",
				body = body,
				commits = commits,
				diffstat = diffstat,
			}, nil)
		end)
	end)
	return scope
end

return M
