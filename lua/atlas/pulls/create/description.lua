-- Builds the initial title and description for `:Atlas create pr`.
--
-- The newest commit supplies the title. For the description, Atlas first reads
-- the configured `pr_template`, or `.github/pull_request_template.md` by
-- default. A non-empty template is used as the description.
--
-- Without a template, Atlas creates a summary placeholder, groups conventional
-- commits into sections, accepts an optional leading `[JIRA-123]`, links commit
-- hashes and issue references, collects those references under Related, and
-- appends the diffstat. If none of the commits use a conventional prefix, Atlas
-- keeps a linked plain commit list and the same diffstat.
--
-- Inspired by:
-- https://github.com/mjveilleux/pr-description.nvim
-- https://github.com/RemoteRabbit/pr-description.nvim

local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")

local DEFAULT_PR_TEMPLATE = ".github/pull_request_template.md"

local URL_PATHS = {
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
	if config.domain_options("jira", "issues") == nil then
		return nil
	end
	local jira = config.provider_options("jira") or {}
	local base_url = vim.trim(jira.base_url or ""):gsub("/+$", "")
	if base_url == "" then
		return nil
	end
	return base_url .. URL_PATHS.jira.issue:gsub("/+$", "")
end

---@param root string
---@return PullsCreateDescriptionLinks
local function links(root)
	local remote = git.local_repository(root)
	return {
		provider = remote and remote.provider or nil,
		repo_url = remote and string.format("https://%s/%s", remote.host, remote.slug) or nil,
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

	if context.repo_url then
		local issue_path = context.urls.issue or "/issues/"
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
---@param diffstat string[]
---@param context PullsCreateDescriptionLinks
---@return string
local function plain_commits(commits, diffstat, context)
	local lines = vim.tbl_map(function(commit)
		return string.format("- %s %s", commit_link(commit.hash, context), add_links(commit.subject, context))
	end, commits)
	if #lines > 0 and #diffstat > 0 then
		table.insert(lines, "")
	end
	add_diffstat(lines, diffstat)
	return table.concat(lines, "\n")
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
---@return string|nil
local function generate(context, head, commits, diffstat)
	if #commits == 0 then
		return nil
	end

	local categories = {}
	local conventional = false
	for _, commit in ipairs(commits) do
		local category, description, parsed = parse_commit(commit.subject)
		conventional = conventional or parsed
		categories[category] = categories[category] or {}
		table.insert(
			categories[category],
			string.format("- %s (%s)", add_links(description, context), commit_link(commit.hash, context))
		)
	end
	if not conventional then
		return nil
	end

	local lines = { "## Summary", "", "<!-- TODO: Describe the change and why it is needed. -->", "", "## Changes", "" }
	local used_sections = {}
	for _, section in ipairs(SECTIONS) do
		if categories[section.key] then
			table.insert(used_sections, section)
		end
	end
	for _, section in ipairs(used_sections) do
		if #used_sections > 1 then
			table.insert(lines, "**" .. section.title .. "**")
			table.insert(lines, "")
		end
		vim.list_extend(lines, categories[section.key])
		table.insert(lines, "")
	end

	local references = related(context, head, commits)
	if #references > 0 then
		table.insert(lines, "## Related")
		table.insert(lines, "")
		vim.list_extend(lines, references)
		table.insert(lines, "")
	end

	add_diffstat(lines, diffstat)

	return vim.trim(table.concat(lines, "\n"))
end

---@param root string
---@param repo_slug string
---@param base string
---@param head string
---@return PullsCreateDescription|nil
---@return string|nil err
function M.build(root, repo_slug, base, head)
	local range, range_err = git.commit_range(root, base, head)
	if not range then
		return nil, range_err
	end
	local commits = git.commits_for_range(root, range)
	local diffstat = git.diff_stat(root, base, head) or {}
	local latest_commit = commits[#commits]
	local body = read_template(root, repo_slug)

	if body == nil then
		local context = links(root)
		body = generate(context, head, commits, diffstat) or plain_commits(commits, diffstat, context)
	end

	return {
		title = latest_commit and latest_commit.subject or "",
		body = body,
		commits = commits,
		diffstat = diffstat,
	}
end

return M
