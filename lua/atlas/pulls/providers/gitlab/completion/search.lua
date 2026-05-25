local M = {}

---@param project string
local function run(project)
	project = vim.trim(tostring(project or ""))
	if project == "" then
		return
	end
	require("atlas").open("pulls", "gitlab", {
		initial_view = {
			name = "Search",
			layout = "compact",
			project = project,
			scope = "all",
		},
	})
end

function M.open()
	vim.ui.input({ prompt = "Project: " }, function(input)
		if input == nil or vim.trim(tostring(input)) == "" then
			return
		end
		run(tostring(input))
	end)
end

return M
