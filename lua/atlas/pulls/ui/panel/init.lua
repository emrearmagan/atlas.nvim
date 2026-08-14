local M = {}

local pr_panel = require("atlas.pulls.ui.panel.pr")
local repo_panel = require("atlas.pulls.ui.panel.repo")
local panel_state = require("atlas.pulls.ui.panel.state")

---@return table
local function inactive_panel()
	if panel_state.current_panel == "repo" then
		return pr_panel
	end
	return repo_panel
end

---@return table
local function active_panel()
	if panel_state.current_panel == "repo" then
		return repo_panel
	end
	return pr_panel
end

function M.is_open()
	return active_panel().is_open()
end

function M.render()
	return active_panel().render()
end

function M.on_select(pr, repo, opts)
	local target_panel = active_panel()
	local prev_panel = inactive_panel()
	prev_panel.deactivate()
	target_panel.activate()
	local detail_buf = require("atlas.ui.layout").buf_id("detail")
	if detail_buf ~= nil and vim.api.nvim_buf_is_valid(detail_buf) then
		require("atlas.pulls.ui.panel.keymaps").register(detail_buf)
	end

	if panel_state.current_panel == "repo" then
		return target_panel.on_select(repo, opts)
	end
	return target_panel.on_select(pr, repo, opts)
end

function M.next_tab()
	return active_panel().next_tab()
end

function M.prev_tab()
	return active_panel().prev_tab()
end

function M.close()
	pr_panel.close()
	repo_panel.close()
	panel_state.reset()
end

return M
