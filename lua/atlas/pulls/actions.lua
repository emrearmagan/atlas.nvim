local M = {}

local footer = require("atlas.ui.components.footer")
local checkout = require("atlas.core.git.checkout")
local logger = require("atlas.core.logger")

---@class PullsActionResult
---@field changed_pr boolean
---@field message string|nil

---@return PullsProvider|nil
local function provider()
	return require("atlas.pulls.state").provider
end

---@param pr PullRequest
---@return string|nil open_cmd
---@return string|nil command
---@return string|nil err
local function diff_open_command(pr)
	local config = require("atlas.config")
	local pulls_cfg = config.options.pulls or {}
	local cmd = vim.trim(tostring((pulls_cfg.diff or {}).open_cmd or ""))
	if cmd == "" then
		return nil, nil, "diff.open_cmd is not configured"
	end

	if vim.fn.exists(":" .. cmd) ~= 2 then
		return nil, nil, string.format("diff.open_cmd command not found: %s", cmd)
	end

	local src = tostring((pr.source or {}).branch or "")
	local dst = tostring((pr.destination or {}).branch or "")
	if src == "" or dst == "" then
		return nil, nil, "PR branch refs are missing"
	end

	local range = "origin/" .. dst .. "...origin/" .. src
	return cmd, cmd .. " " .. range, nil
end

---@param pr PullRequest
function M.copy_id(pr)
	vim.fn.setreg("+", tostring(pr.id))
	footer.notify("success", string.format("Copied #%s to clipboard", tostring(pr.id)), 1200)
end

---@param pr PullRequest
function M.copy_url(pr)
	local url = pr.link and pr.link.html
	if url == nil or url == "" then
		footer.notify("warn", "No URL available")
		return
	end
	vim.fn.setreg("+", url)
	footer.notify("success", "Copied URL to clipboard", 1200)
end

---@param pr PullRequest
function M.open_in_browser(pr)
	local url = pr.link and pr.link.html
	if url == nil or url == "" then
		footer.notify("warn", "No URL available")
		return
	end
	vim.ui.open(url)
	footer.notify("info", "Opened in browser")
end

---@param pr PullRequest
---@param buf integer
function M.show_details(pr, buf)
	local helper = require("atlas.pulls.ui.main.helper")
	local info_popup = require("atlas.ui.popups.info")
	local lines, highlights = helper.pr_popup_content(pr)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = buf,
	})
end

---@param pr PullRequest
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil)|nil
function M.open_actions(pr, source, on_done)
	local p = provider()
	if not p or not p.open_actions then
		return
	end
	p.open_actions(pr, source, function(result)
		if result ~= nil and result.changed_pr then
			local controller = require("atlas.pulls.ui.main.controller")
			controller.refresh_pr(pr)
		end
		if on_done then
			on_done(result)
		end
	end)
end

---@param pr PullRequest
function M.open_diff(pr)
	local resolved_path, resolve_err =
		checkout.resolve_repo_path_for_pr(pr, { require_git = true, require_existing = true })
	if not resolved_path then
		footer.notify("warn", tostring(resolve_err or "Local repo not found"))
		return
	end

	local open_cmd, command, cmd_err = diff_open_command(pr)
	if cmd_err or not open_cmd or not command then
		local level = cmd_err == "PR branch refs are missing" and "warn" or "error"
		footer.notify(level, tostring(cmd_err))
		return
	end

	local repo_path = vim.fn.fnameescape(resolved_path)

	footer.notify("loading", "Fetching remote branches...")
	checkout.fetch_pr_branches(pr, resolved_path, function(fetch_err)
		if fetch_err then
			logger.logerror("actions.open_diff fetch failed", { pr_id = pr.id, error = tostring(fetch_err) })
			footer.notify("error", "Fetch failed: " .. tostring(fetch_err))
			return
		end

		logger.loginfo("actions.open_diff", { pr_id = pr.id, repo_path = resolved_path, command = command })
		local ok, err = pcall(function()
			if open_cmd == "DiffviewOpen" then
				local prev_path = vim.fn.fnameescape(vim.fn.getcwd())
				vim.cmd("cd " .. repo_path)
				local cmd_ok, cmd_err2 = pcall(function()
					vim.cmd(command)
				end)
				vim.cmd("cd " .. prev_path)
				if not cmd_ok then
					error(cmd_err2)
				end
				return
			end

			if open_cmd == "CodeDiff" then
				vim.cmd("tabnew")
				local launcher_tab = vim.api.nvim_get_current_tabpage()
				local launcher_buf = vim.api.nvim_get_current_buf()
				vim.bo[launcher_buf].buflisted = false
				vim.bo[launcher_buf].bufhidden = "wipe"
				-- CodeDiff opens its own tab, so close the temporary one.
				vim.api.nvim_create_autocmd("User", {
					pattern = "CodeDiffOpen",
					once = true,
					callback = function()
						vim.schedule(function()
							if vim.api.nvim_tabpage_is_valid(launcher_tab) then
								local tabnr = vim.api.nvim_tabpage_get_number(launcher_tab)
								pcall(vim.cmd, tabnr .. "tabclose")
							end
							if vim.api.nvim_buf_is_valid(launcher_buf) then
								pcall(vim.api.nvim_buf_delete, launcher_buf, { force = true })
							end
						end)
					end,
				})

				vim.cmd("cd " .. repo_path)
				vim.cmd(command)
				return
			end

			vim.cmd("tabnew")
			vim.cmd("cd " .. repo_path)
			vim.cmd(command)
		end)

		if not ok then
			logger.logerror("actions.open_diff failed", { pr_id = pr.id, command = command, error = tostring(err) })
			footer.notify("error", string.format("%s failed: %s", open_cmd, tostring(err)))
			return
		end

		footer.notify("success", "Opened PR diff", 1200)
	end)
end

---@param pr PullRequest
function M.checkout(pr)
	footer.notify("loading", string.format("Checking out PR #%s", tostring(pr.id or "")))
	checkout.checkout_pr(pr, function(_, err)
		vim.schedule(function()
			if err then
				footer.notify("error", string.format("Checkout failed: %s", tostring(err)))
				return
			end
			footer.notify("success", string.format("Checked out PR #%s", tostring(pr.id or "")))
		end)
	end)
end

---@param pr PullRequest
function M.refresh(pr)
	local controller = require("atlas.pulls.ui.main.controller")
	controller.refresh_pr(pr)
end

function M.refresh_view()
	local controller = require("atlas.pulls.ui.main.controller")
	controller.refresh_current_view()
end

function M.search()
	local p = provider()
	if not p or not p.search then
		return
	end
	p.search()
end

return M
