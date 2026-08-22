local M = {}

local config = require("atlas.config")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local picker = require("atlas.picker")
local providers = require("atlas.providers")

---@param opts AtlasConfig|nil
function M.setup(opts)
	config.setup(opts)
	require("atlas.commands").setup()
	require("atlas.core.logger").clear()
end

local function bootstrap_common()
	require("atlas.ui.shared.highlights").setup()

	local commands = { { name = "Atlas", desc = "Choose a command" } }
	for _, command in ipairs(require("atlas.commands").commands) do
		table.insert(commands, { name = "Atlas " .. (command.usage or command.name), desc = command.description })
	end
	table.insert(commands, { name = "AtlasDiff", desc = "Open native diff or pull request" })
	require("atlas.ui.popups.help").register_command(
		"Commands",
		commands,
		{ index = 999, buffer = require("atlas.ui.layout").buf_id("main") }
	)
end

---@param domain "pulls"|"issues"
---@return string[]
local function configured_provider_ids(domain)
	return vim.tbl_map(function(provider)
		return provider.id
	end, providers.configured(domain))
end

---@param domain "pulls"|"issues"
---@param id string
---@return PullsProvider|IssuesProvider|nil
local function load_provider(domain, id)
	if config.domain_options(id, domain) == nil then
		notify.error(string.format("%s provider not configured: %s", domain, id))
		return nil
	end
	local provider = providers.load(id, domain)
	if not provider then
		notify.error(string.format("Unknown %s provider: %s", domain, id))
	end
	return provider
end

---@param domain "pulls"|"issues"
---@param id string
---@param opts? { initial_view?: table }
local function open_with_provider(domain, id, opts)
	local layout = require("atlas.ui.layout")

	layout.ensure_open()
	bootstrap_common()
	local provider = load_provider(domain, id)
	if provider == nil then
		return
	end

	if domain == "pulls" then
		---@cast provider PullsProvider
		layout.set_context(function()
			require("atlas.pulls").dispose()
		end, { domain = domain, provider = provider.id })
		layout.set_render_callback(function()
			require("atlas.pulls").render()
			local panel = require("atlas.pulls.ui.panel")
			if panel.is_open() then
				panel.render()
			end
		end)
		require("atlas.pulls").init(provider, opts)
	else
		---@cast provider IssuesProvider
		layout.set_context(function()
			require("atlas.issues").dispose()
		end, { domain = domain, provider = provider.id })
		layout.set_render_callback(function()
			require("atlas.issues").render()
			local panel = require("atlas.issues.ui.panel")
			if panel.is_open() then
				panel.render()
			end
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
		notify.error(string.format("No %s providers configured", domain))
		return
	end
	if #ids == 1 then
		open_with_provider(domain, ids[1], opts)
		return
	end

	picker.select({
		title = "Select provider:",
		items = ids,
		format_item = function(id)
			local provider = providers[id]
			return provider and provider.name(domain) or id
		end,
		on_select = function(choice)
			if choice == nil then
				return
			end
			open_with_provider(domain, choice, opts)
		end,
	})
end

return M
