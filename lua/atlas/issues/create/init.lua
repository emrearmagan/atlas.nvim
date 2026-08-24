local M = {}

local notify = require("atlas.core.notify")
local picker = require("atlas.picker")
local providers = require("atlas.providers")

---@return { label: string, provider: IssuesProvider }[]
local function build_choices()
	local choices = {}
	local actions = require("atlas.issues.actions")
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
	require("atlas.issues.actions").run("create_issue", { provider = provider })
end

function M.start()
	local choices = build_choices()

	if #choices == 0 then
		notify.error("No issue-capable provider is configured", { vim_notify = true })
		return
	end

	if #choices == 1 then
		create(choices[1].provider)
		return
	end

	local labels = {}
	for _, c in ipairs(choices) do
		table.insert(labels, c.label)
	end

	picker.select({
		title = "Create issue with:",
		items = labels,
		on_select = function(_, index)
			if index == nil then
				return
			end
			create(choices[index].provider)
		end,
	})
end

return M
