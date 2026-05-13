local M = {}

local logger = require("atlas.core.logger")

---@param opts AtlasConfig|nil
function M.setup(opts)
	require("atlas.config").setup(opts)
	require("atlas.core.logger").clear()
end

local function bootstrap_common()
	require("atlas.ui.shared.highlights").setup()
	require("atlas.ui.components.footer").setup()

	require("atlas.ui.popups.help").register_command("Commands", {
		{ name = "AtlasPulls", desc = "Open pulls" },
		{ name = "AtlasIssues", desc = "Open issues" },
		{ name = "AtlasSearch", desc = "Search across providers" },
		{ name = "AtlasClearCache", desc = "Clear Atlas cache" },
		{ name = "AtlasLogs", desc = "Open Atlas logs" },
	}, { index = 999, buffer = require("atlas.ui.layout").buf_id("main") })
end

---@param domain "pulls"|"issues"
---@return string[]
local function configured_provider_ids(domain)
	local config = require("atlas.config")
	local cfg = config.options and config.options[domain] or nil
	local providers = cfg and cfg.providers or {}
	local order = domain == "pulls" and { "bitbucket", "github" } or { "jira", "github" }
	local ids = {}
	for _, id in ipairs(order) do
		if providers[id] then
			table.insert(ids, id)
		end
	end
	return ids
end

---@param id string
---@return PullsProvider|nil
local function load_pulls_provider(id)
	if id == "bitbucket" then
		return require("atlas.pulls.providers.bitbucket")
	elseif id == "github" then
		return require("atlas.pulls.providers.github")
	end
	vim.notify(string.format("[Atlas] Unknown pulls provider: %s", id), vim.log.levels.ERROR)
	return nil
end

---@param id string
---@return IssuesProvider|nil
local function load_issues_provider(id)
	if id == "jira" then
		return require("atlas.issues.providers.jira")
	elseif id == "github" then
		return require("atlas.issues.providers.github")
	end
	vim.notify(string.format("[Atlas] Unknown issues provider: %s", id), vim.log.levels.ERROR)
	return nil
end

---@param domain "pulls"|"issues"
---@param id string
---@param opts? { initial_view?: table }
local function open_with_provider(domain, id, opts)
	local layout = require("atlas.ui.layout")

	layout.ensure_open()
	bootstrap_common()
	layout.open()

	if domain == "pulls" then
		local provider = load_pulls_provider(id)
		if provider == nil then
			return
		end
		layout.set_render_callback(function()
			require("atlas.pulls").render()
			local panel = require("atlas.pulls.ui.panel")
			if panel.is_open() then
				panel.render()
			end
		end)
		require("atlas.pulls").init(provider, opts)
	else
		local provider = load_issues_provider(id)
		if provider == nil then
			return
		end
		layout.set_render_callback(function()
			require("atlas.issues").render()
		end)
		require("atlas.issues").init(provider, opts)
	end
end

---@param domain "pulls"|"issues"
---@param provider_id string|nil
---@param opts? { initial_view?: table }
function M.open(domain, provider_id, opts)
	logger.loginfo("Atlas open requested", { domain = domain, provider_id = provider_id })

	if provider_id ~= nil and provider_id ~= "" then
		open_with_provider(domain, provider_id, opts)
		return
	end

	local ids = configured_provider_ids(domain)
	if #ids == 0 then
		vim.notify(string.format("[Atlas] No %s providers configured", domain), vim.log.levels.ERROR)
		return
	end
	if #ids == 1 then
		open_with_provider(domain, ids[1], opts)
		return
	end

	vim.ui.select(ids, {
		prompt = string.format("Select provider:"),
		format_item = function(id)
			return id:sub(1, 1):upper() .. id:sub(2)
		end,
	}, function(choice)
		if choice == nil then
			return
		end
		open_with_provider(domain, choice, opts)
	end)
end

return M
