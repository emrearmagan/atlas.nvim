local M = {}

local actions = require("atlas.issues.actions")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")

---@return { label: string, provider: IssuesProvider }[]
local function build_choices()
	local choices = {}
	for _, provider_config in ipairs(providers.configured("issues")) do
		local provider = providers.load(provider_config.id, "issues")
		if provider then
			---@cast provider IssuesProvider
			if actions.is_available("create_issue", { provider = provider }) then
				table.insert(choices, { label = provider_config.name, provider = provider })
			end
		end
	end

	return choices
end

---@param provider IssuesProvider
local function create(provider)
	actions.run("create_issue", { provider = provider })
end

local function pick()
	local choices = build_choices()

	if #choices == 0 then
		notify.error("No issue-capable provider is configured", { vim_notify = true })
		return
	end

	if #choices == 1 then
		create(choices[1].provider)
		return
	end

	picker.select({
		title = "Create issue with:",
		items = choices,
		format_item = function(choice)
			return choice.label
		end,
		on_select = function(choice)
			if choice then
				create(choice.provider)
			end
		end,
	})
end

---@param provider_id string
local function create_with(provider_id)
	for _, choice in ipairs(build_choices()) do
		if choice.provider.id == provider_id then
			create(choice.provider)
			return
		end
	end
	local name = vim.tbl_get(providers, provider_id, "name") or provider_id
	notify.warn("Creating issues is not available for " .. name, { vim_notify = true })
	pick()
end

---@param target string|nil A provider ID, "." for the current repository's provider, or nil to ask.
function M.issue(target)
	if not target then
		pick()
		return
	end
	if target ~= "." then
		create_with(target:lower())
		return
	end

	git.local_repository(nil, function(repository)
		if not repository then
			notify.warn("No supported Git repository found", { vim_notify = true })
			pick()
			return
		end
		create_with(repository.provider)
	end)
end

return M
