local M = {}

local prompt = require("atlas.commands.search.prompt")
local query_api = require("atlas.providers.github.completion.query")

---@param query string
---@return "pulls"|"issues"
local function route(query)
	if query:find("is:issue") then
		return "issues"
	end
	return "pulls"
end

---@param query string
local function run(query)
	query = vim.trim(tostring(query or ""))
	if query == "" then
		return
	end
	require("atlas").open(route(query), "github", {
		initial_view = { name = "Search", layout = "compact", search = query },
	})
end

---@param default? string
function M.open(default)
	prompt.open({
		name = "AtlasGitHubSearch",
		complete = query_api.complete_cmdline,
		on_submit = run,
		default = default or "is:pr ",
	})
end

return M
