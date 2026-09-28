local M = {}

local config = require("atlas.config")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")
local issues_highlights = require("atlas.issues.ui.highlights")
local pulls_highlights = require("atlas.pulls.ui.highlights")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")

local function setup_highlights()
	pulls_highlights.setup()
	issues_highlights.setup()
end

---@param opts AtlasConfig|nil
function M.setup(opts)
	config.setup(opts)
	setup_highlights()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("AtlasHighlights", { clear = true }),
		callback = setup_highlights,
	})

	require("atlas.commands").setup()
	logger.clear()
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
	if providers.domain(id, domain) == nil then
		notify.error(string.format("Unknown %s provider: %s", domain, id), { vim_notify = true })
		return nil
	end
	if config.provider_options(id) == nil then
		notify.error(string.format("%s provider not configured: %s", domain, id), { vim_notify = true })
		return nil
	end
	return providers.load(id, domain)
end

---@param domain "pulls"|"issues"
---@param id string
---@param opts? { initial_view?: table }
local function open_with_provider(domain, id, opts)
	local provider = load_provider(domain, id)
	if provider == nil then
		return
	end

	require("atlas.ui.dashboard").open(domain, provider.id)
	if domain == "pulls" then
		---@cast provider PullsProvider
		require("atlas.pulls").init(provider, opts)
	else
		---@cast provider IssuesProvider
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
		notify.error(string.format("No %s providers configured", domain), { vim_notify = true })
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
			return provider and provider.name or id
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
