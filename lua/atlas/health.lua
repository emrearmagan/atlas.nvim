local M = {}

local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local providers = require("atlas.providers")

---@param bin string
---@param label string
local function check_executable(bin, label)
	if vim.fn.executable(bin) == 1 then
		vim.health.ok(string.format("%s found: %s", label, bin))
		return
	end
	vim.health.error(string.format("%s missing: %s", label, bin))
end

---@param section table
---@param keys string[]
---@param label string
local function check_credentials(section, keys, label)
	local missing = {}
	for _, key in ipairs(keys) do
		local v = section[key]
		if v == nil or v == "" then
			table.insert(missing, key)
		end
	end

	if #missing == 0 then
		vim.health.ok(string.format("%s credentials configured", label))
	else
		vim.health.warn(string.format("%s credentials missing: %s", label, table.concat(missing, ", ")))
	end
end

---@param url any
---@param label string
local function check_https_url(url, label)
	local s = tostring(url or "")
	if s == "" then
		vim.health.warn(string.format("%s is empty", label))
	elseif not s:match("^https://") then
		vim.health.warn(string.format("%s should start with https:// (current: %s)", label, s))
	else
		vim.health.ok(string.format("%s looks valid", label))
	end
end

---@param views any
---@param label string
local function check_views(views, label)
	if type(views) ~= "table" or #views == 0 then
		vim.health.warn(string.format("%s: no views configured", label))
	else
		vim.health.ok(string.format("%s: %d view(s) configured", label, #views))
	end
end

local function check_pulls()
	local pulls = config.options and config.options.pulls or nil
	if not pulls then
		vim.health.info("Pulls not configured")
		return
	end

	local repo_paths = (pulls.repo_config or {}).paths or {}
	if vim.tbl_isempty(repo_paths) and #providers.configured("pulls") == 0 then
		vim.health.info("Pulls not configured")
		return
	end
	if vim.tbl_isempty(repo_paths) then
		vim.health.warn("pulls.repo_config.paths is empty")
	else
		vim.health.ok(
			string.format(
				"pulls.repo_config.paths configured (%d mapping%s)",
				vim.tbl_count(repo_paths),
				vim.tbl_count(repo_paths) == 1 and "" or "s"
			)
		)
	end

	local diff_cmd = tostring((pulls.diff or {}).open_cmd or "")
	if diff_cmd == "" then
		vim.health.warn("pulls.diff.open_cmd is empty")
	elseif vim.fn.exists(":" .. diff_cmd) == 2 then
		vim.health.ok(string.format("pulls.diff.open_cmd available: %s", diff_cmd))
	else
		vim.health.error(string.format("pulls.diff.open_cmd not found: %s", diff_cmd))
	end
end

local function check_bitbucket()
	local pulls = config.domain_options("bitbucket", "pulls")
	if pulls == nil then
		vim.health.info("Bitbucket not configured")
		return
	end

	check_credentials(config.provider_options("bitbucket") or {}, { "user", "token" }, "Bitbucket")
	check_views(pulls.views, "Bitbucket pulls")
end

local function check_github()
	local pulls = config.domain_options("github", "pulls")
	local issues = config.domain_options("github", "issues")
	if pulls == nil and issues == nil then
		vim.health.info("GitHub not configured")
		return
	end

	if vim.fn.executable("gh") ~= 1 then
		vim.health.error("gh CLI not found", { "Install from https://cli.github.com" })
		return
	end
	vim.health.ok("gh CLI found")

	if vim.system({ "gh", "auth", "status" }, { text = true }):wait().code ~= 0 then
		vim.health.error("gh not authenticated", { "Run: gh auth login" })
		return
	end
	vim.health.ok("gh authenticated")

	if pulls then
		check_views(pulls.views, "GitHub pulls")
	end
	if issues then
		check_views(issues.views, "GitHub issues")
	end
end

local function check_gitlab()
	local pulls = config.domain_options("gitlab", "pulls")
	local issues = config.domain_options("gitlab", "issues")
	if pulls == nil and issues == nil then
		vim.health.info("GitLab not configured")
		return
	end

	local provider = config.provider_options("gitlab") or {}
	if pulls then
		check_credentials(provider, { "base_url", "token" }, "GitLab pulls")
		check_https_url(provider.base_url, "providers.gitlab.base_url")
		check_views(pulls.views, "GitLab pulls")
	end
	if issues then
		check_credentials(provider, { "base_url", "token" }, "GitLab issues")
		check_https_url(provider.base_url, "providers.gitlab.base_url")
		check_views(issues.views, "GitLab issues")
	end
end

local function check_gitea()
	local pulls = config.domain_options("gitea", "pulls")
	local issues = config.domain_options("gitea", "issues")
	if pulls == nil and issues == nil then
		vim.health.info("Gitea / Forgejo not configured")
		return
	end

	local provider = config.provider_options("gitea") or {}
	local label = "Gitea / Forgejo"
	local base_url = vim.trim(tostring(provider.base_url or ""))
	if base_url == "" then
		vim.health.error(label .. " base_url is required")
	elseif not base_url:match("^https?://[^/]+") then
		vim.health.error(label .. " base_url must start with http:// or https://")
	else
		vim.health.ok(label .. " base_url configured")
	end
	if vim.trim(tostring(provider.token or "")) == "" then
		vim.health.error(label .. " token is required")
	else
		vim.health.ok(label .. " token configured")
	end
	local api_type = tostring(provider.api_type or "gitea")
	if api_type == "forgejo" or api_type == "gitea" then
		vim.health.ok(string.format("%s API type: %s", label, api_type))
	else
		vim.health.error(string.format("%s api_type must be 'forgejo' or 'gitea'", label))
	end

	for _, entry in ipairs({ { "pulls", pulls }, { "issues", issues } }) do
		local domain, options = entry[1], entry[2]
		if options then
			local domain_label = string.format("%s %s", label, domain)
			if domain == "issues" and options.views == nil then
				vim.health.ok(domain_label .. ": using default views")
			else
				check_views(options.views, domain_label)
			end
		end
	end
end

local function check_jira()
	local issues = config.domain_options("jira", "issues")
	if issues == nil then
		vim.health.info("Jira not configured")
		return
	end

	local provider = config.provider_options("jira") or {}
	check_credentials(provider, { "email", "token" }, "Jira")
	check_https_url(provider.base_url, "providers.jira.base_url")
	check_views(issues.views, "Jira")
end

local function validate_keymaps()
	local by_context = keymaps.validate()
	local context_names = vim.tbl_keys(by_context)
	table.sort(context_names)

	local has_conflicts = false
	for _, context_name in ipairs(context_names) do
		local conflicts = by_context[context_name] or {}
		local keys = vim.tbl_keys(conflicts)
		table.sort(keys)
		if #keys == 0 then
			vim.health.ok(string.format("%s: no conflicting mapped keys", context_name))
		else
			has_conflicts = true
			vim.health.warn(string.format("%s: %d conflicting key(s)", context_name, #keys))
			for _, key in ipairs(keys) do
				vim.health.warn(string.format("  %s -> %s", key, table.concat(conflicts[key], ", ")))
			end
		end
	end

	if not has_conflicts and #context_names == 0 then
		vim.health.ok("No conflicting mapped keys")
	end
end

function M.check()
	vim.health.start("Requirements")
	if vim.fn.has("nvim-0.10") == 0 then
		vim.health.error("Neovim >= 0.10 required")
	else
		vim.health.ok("Neovim version compatible")
	end
	check_executable("git", "Git")
	check_executable("curl", "curl")

	vim.health.start("Pulls")
	check_pulls()

	vim.health.start("Bitbucket")
	check_bitbucket()

	vim.health.start("GitHub")
	check_github()

	vim.health.start("GitLab")
	check_gitlab()

	vim.health.start("Gitea / Forgejo")
	check_gitea()

	vim.health.start("Jira")
	check_jira()

	vim.health.start("Keymaps")
	validate_keymaps()
end

return M
