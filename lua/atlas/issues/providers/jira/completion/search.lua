local M = {}

local prompt = require("atlas.commands.search.prompt")
local jql_api = require("atlas.issues.providers.jira.completion.jql")

local autocomplete_fetch_started = false

---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete(arglead, cmdline, cursorpos)
	if not autocomplete_fetch_started then
		autocomplete_fetch_started = true
		jql_api.get_autocomplete_data(function() end, { force_load = false })
	end
	return jql_api.complete_cmdline(arglead, cmdline, cursorpos)
end

---@param query string
function M.open_query(query)
	query = vim.trim(tostring(query or ""))
	if query == "" then
		return
	end

	local view = { name = "Search (JQL)", layout = "compact", jql = query }
	require("atlas").open("issues", "jira", { initial_view = view })
end

---@param default? string
function M.open(default)
	prompt.open({
		name = "AtlasJqlSearch",
		complete = complete,
		on_submit = M.open_query,
		default = default,
	})
end

return M
