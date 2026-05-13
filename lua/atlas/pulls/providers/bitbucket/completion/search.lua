local M = {}

---@param workspace string
---@param repo string
local function run(workspace, repo)
	workspace = vim.trim(tostring(workspace or ""))
	repo = vim.trim(tostring(repo or ""))
	if workspace == "" or repo == "" then
		return
	end
	require("atlas").open("pulls", "bitbucket", {
		initial_view = {
			name = "Search",
			layout = "compact",
			repos = { { workspace = workspace, repo = repo } },
		},
	})
end

function M.open()
	vim.ui.input({ prompt = "Workspace: " }, function(workspace)
		if workspace == nil or vim.trim(tostring(workspace)) == "" then
			return
		end
		vim.ui.input({ prompt = "Repo: " }, function(repo)
			if repo == nil or vim.trim(tostring(repo)) == "" then
				return
			end
			run(tostring(workspace), tostring(repo))
		end)
	end)
end

return M
