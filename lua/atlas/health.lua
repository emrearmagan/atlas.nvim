local M = {}

local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local providers = require("atlas.providers")
local diff_keymaps = require("atlas.pulls.diff.keymaps")
local has_codediff, codediff = pcall(require, "codediff.config")

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

---@param id AtlasProviderId
local function check_provider_views(id)
	local provider = providers[id]

	for _, domain in ipairs({ "pulls", "issues" }) do
		if provider.domains[domain] then
			local options = config.domain_options(id, domain) or {}
			local views = options.views or {}
			local label = string.format("%s %s", provider.name, domain)
			if type(views) ~= "table" then
				vim.health.warn(string.format("%s: no views configured", label))
			elseif #views == 0 then
				vim.health.ok(string.format("%s: using default views", label))
			else
				vim.health.ok(string.format("%s: %d view(s) configured", label, #views))
			end
		end
	end
end

local function check_pulls()
	local pulls = config.options.pulls
	local diff_cmd = config.diff_command()
	local configured = vim.trim(pulls.diff.open_cmd or "auto")
	local automatic = configured == "auto" or configured == ""
	vim.health.ok(string.format("Diff viewer: %s%s", diff_cmd, automatic and " (auto)" or ""))

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

	local lsp = pulls.diff.lsp
	local lsp_ok, lsp_err = require("atlas.core.git.worktree").validate(lsp)
	if not lsp_ok then
		vim.health.error(string.format("pulls.diff.lsp is invalid: %s", tostring(lsp_err)))
	elseif not lsp.enabled then
		vim.health.info("pulls.diff.lsp.enabled is off (diff buffers have no language server)")
	elseif diff_cmd ~= "AtlasDiff" and diff_cmd ~= "CodeDiff" then
		vim.health.warn(
			string.format("pulls.diff.lsp.enabled requires open_cmd AtlasDiff or CodeDiff (got %s)", diff_cmd)
		)
	else
		vim.health.ok("pulls.diff.lsp enabled")
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

	local hostname = providers.github.hostname()
	local result = vim.system({ "gh", "auth", "status", "--hostname", hostname }, { text = true }):wait(5000)
	if result.code == 0 then
		vim.health.ok("gh authenticated for " .. hostname)
		return
	end
	vim.health.error(
		"GitHub authentication check failed for " .. hostname,
		{ "Run: gh auth login --hostname " .. hostname }
	)
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

local function check_azure()
	local provider = config.provider_options("azure")
	if provider == nil then
		vim.health.info("Azure DevOps not configured")
		return
	end
	check_credentials(provider, { "base_url", "token" }, "Azure DevOps")
	check_https_url(provider.base_url, "providers.azure.base_url")
	check_provider_views("azure")
end

local function check_jira()
	local provider = config.provider_options("jira")
	if provider == nil then
		vim.health.info("Jira not configured")
		return
	end

	local credentials = { "base_url", "token" }
	if provider.auth_method ~= "bearer" then
		table.insert(credentials, "email")
	end
	check_credentials(provider, credentials, "Jira")
	check_https_url(provider.base_url, "providers.jira.base_url")
	check_provider_views("jira")
end

local function check_codediff_keymaps()
	if not has_codediff then
		vim.health.info("CodeDiff keymap check skipped: CodeDiff config is unavailable")
		return
	end

	local overlaps = {}
	for group, actions in pairs(diff_keymaps.action_ids) do
		local atlas_keys = {}
		local function add(action, keys)
			if type(keys) == "string" then
				keys = { keys }
			end
			for _, key in ipairs(keys or {}) do
				local normalized = vim.api.nvim_replace_termcodes(key, true, true, true)
				atlas_keys[normalized] = atlas_keys[normalized] or {}
				table.insert(atlas_keys[normalized], { action = action, label = action .. " (" .. key .. ")" })
			end
		end

		for _, action in ipairs(actions) do
			add(action, keymaps.resolve(action))
		end
		for index, mapping in ipairs(config.options.keymaps.pulls.custom or {}) do
			add(string.format("pulls.custom[%d]", index), mapping.key)
		end

		for action, keys in pairs(codediff.options.keymaps[group]) do
			if type(keys) == "string" then
				keys = { keys }
			end
			if type(keys) == "table" then
				for _, key in ipairs(keys) do
					local normalized = vim.api.nvim_replace_termcodes(key, true, true, true)
					for _, atlas_action in ipairs(atlas_keys[normalized] or {}) do
						local help_override = atlas_action.action == "ui.help"
							and group == "view"
							and action == "show_help"
						if not help_override then
							local message = string.format(
								"CodeDiff: Atlas %s overlaps %s.%s (%s)",
								atlas_action.label,
								group,
								action,
								key
							)
							table.insert(overlaps, message)
						end
					end
				end
			end
		end
	end

	table.sort(overlaps)
	if #overlaps == 0 then
		vim.health.ok("No configured key overlaps with CodeDiff")
		return
	end
	for _, overlap in ipairs(overlaps) do
		vim.health.warn(overlap)
	end
end

---@param section_path string[]
---@param default_bookmarks_key string
---@return table<string, string[]>
local function view_key_conflicts(section_path, default_bookmarks_key)
	local node = config.options ---@type any
	for _, key in ipairs(section_path) do
		if type(node) ~= "table" then
			return {}
		end
		node = node[key]
	end
	if type(node) ~= "table" then
		return {}
	end

	---@type table<string, table<string, true>>
	local seen = {}
	for _, view in ipairs(node.views or {}) do
		local key = type(view) == "table" and view.key or nil
		if type(key) == "string" and key ~= "" then
			seen[key] = seen[key] or {}
			seen[key][tostring(view.name or "<view>")] = true
		end
	end

	local bookmarks = node.bookmarks
	if default_bookmarks_key ~= "" then
		local bk = tostring((type(bookmarks) == "table" and bookmarks.key) or default_bookmarks_key)
		if bk ~= "" then
			seen[bk] = seen[bk] or {}
			seen[bk][tostring((type(bookmarks) == "table" and bookmarks.label) or default_bookmarks_key) .. " (bookmarks)"] =
				true
		end
	end

	---@type table<string, string[]>
	local conflicts = {}
	for key, names in pairs(seen) do
		local list = vim.tbl_keys(names)
		table.sort(list)
		if #list > 1 then
			conflicts[key] = list
		end
	end
	return conflicts
end

local function validate_keymaps()
	local by_context = keymaps.validate()
	for _, domain in ipairs({ "issues", "pulls" }) do
		for _, provider in ipairs(providers.list(domain)) do
			local provider_domain = provider.domains[domain]
			local conflicts = view_key_conflicts({ domain, provider.id }, provider_domain.bookmark_key or "S")
			if next(conflicts) ~= nil then
				by_context[string.format("%s %s views", provider.name:lower(), domain)] = conflicts
			end
		end
	end

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

	vim.health.start("Azure DevOps")
	check_azure()

	vim.health.start("Jira")
	check_jira()

	vim.health.start("Keymaps")
	validate_keymaps()
	check_codediff_keymaps()
end

return M
