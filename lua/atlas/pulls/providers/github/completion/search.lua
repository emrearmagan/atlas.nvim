local M = {}

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
	vim.ui.input({
		prompt = "GitHub search: ",
		default = default or "is:pr ",
	}, function(input)
		run(input ~= nil and tostring(input) or "")
	end)
end

return M
