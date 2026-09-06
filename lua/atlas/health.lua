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

---@param id AtlasProviderId
local function check_provider_views(id)
	local provider = providers[id]
	if not provider then
		return
	end

	for _, domain in ipairs({ "pulls", "issues" }) do
		if provider.domains[domain] then
			local options = config.domain_options(id, domain) or {}
			local views = options.views or {}
			local label = string.format("%s %s", provider.name, domain)
			if #views == 0 then
				vim.health.ok(string.format("%s: using default views", label))
			else
				check_views(views, label)
			end
		end
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
	local provider = config.provider_options("bitbucket")
	if provider == nil then
		vim.health.info("Bitbucket not configured")
		return
	end

	check_credentials(provider, { "user", "token" }, "Bitbucket")
	check_provider_views("bitbucket")
end

local function check_github()
	if config.provider_options("github") == nil then
		vim.health.info("GitHub not configured")
		return
	end
	check_provider_views("github")

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
end

local function check_gitlab()
	local provider = config.provider_options("gitlab")
	if provider == nil then
		vim.health.info("GitLab not configured")
		return
	end

	check_credentials(provider, { "base_url", "token" }, "GitLab")
	check_https_url(provider.base_url, "providers.gitlab.base_url")
	check_provider_views("gitlab")
end

local function check_jira()
	local provider = config.provider_options("jira")
	if provider == nil then
		vim.health.info("Jira not configured")
		return
	end

	check_credentials(provider, { "email", "token" }, "Jira")
	check_https_url(provider.base_url, "providers.jira.base_url")
	check_provider_views("jira")
end

local function check_shortcut()
	local provider = config.provider_options("shortcut")
	if provider == nil then
		vim.health.info("Shortcut not configured")
		return
	end

	check_credentials(provider, { "token" }, "Shortcut")
	check_provider_views("shortcut")
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

	vim.health.start("Jira")
	check_jira()

	vim.health.start("Shortcut")
	check_shortcut()

	vim.health.start("Keymaps")
	validate_keymaps()
end

return M
