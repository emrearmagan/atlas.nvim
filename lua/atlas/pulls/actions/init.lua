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

---@param requested AtlasPullsDiffOpenCommand|nil
---@return AtlasPullsDiffOpenCommand|nil open_cmd
---@return string|nil err
local function diff_open_command(requested)
	local config = require("atlas.config")
	local pulls_cfg = config.options.pulls or {}
	local cmd = vim.trim(tostring(requested or (pulls_cfg.diff or {}).open_cmd or ""))
	if cmd == "" then
		return nil, "diff.open_cmd is not configured"
	end
	if cmd ~= "AtlasDiff" and cmd ~= "DiffviewOpen" and cmd ~= "CodeDiff" then
		return nil, "Unsupported diff.open_cmd: " .. cmd
	end

	if vim.fn.exists(":" .. cmd) ~= 2 then
		return nil, string.format("diff.open_cmd command not found: %s", cmd)
	end

	---@cast cmd AtlasPullsDiffOpenCommand
	return cmd, nil
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

local PROVIDER_ACTIONS_MODULES = {
	github = "atlas.pulls.providers.github.actions",
	gitlab = "atlas.pulls.providers.gitlab.actions",
	bitbucket = "atlas.pulls.providers.bitbucket.actions",
}

---@param pr PullRequest
---@param action_id string
---@param source "main"|"panel"|nil
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
function M.run_action(pr, action_id, source, on_done)
	local p = provider()
	local mod_path = p and PROVIDER_ACTIONS_MODULES[p.id]
	if not mod_path then
		if on_done then
			on_done(nil, "Provider does not support actions")
		end
		return
	end
	local ok, mod = pcall(require, mod_path)
	if not ok or type(mod) ~= "table" or type(mod.run) ~= "function" then
		if on_done then
			on_done(nil, "Provider actions module unavailable")
		end
		return
	end
	mod.run(action_id, { pr = pr, source = source }, function(result, err)
		if result ~= nil and result.changed_pr then
			local controller = require("atlas.pulls.ui.main.controller")
			controller.refresh_pr(pr)
		end
		if on_done then
			on_done(result, err)
		end
	end)
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

---@class PullsDiffRangeOpenOptions
---@field git_root string
---@field base_revision string
---@field head_revision string
---@field fetch_branches (fun(on_done: fun(err: string|nil)): { cancel: fun() }|nil)|nil
---@field open_cmd AtlasPullsDiffOpenCommand|nil

---@param repo_path string
---@param range string
---@return string|nil err
local function open_diffview(repo_path, range)
	local previous_path = vim.fn.fnameescape(vim.fn.getcwd())
	local ok, err = pcall(function()
		vim.cmd("cd " .. vim.fn.fnameescape(repo_path))
		local opened, open_err = pcall(vim.cmd, "DiffviewOpen " .. range)
		vim.cmd("cd " .. previous_path)
		if not opened then
			error(open_err)
		end
	end)
	return not ok and tostring(err) or nil
end

---@param repo_path string
---@param range string
---@param view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return { cancel: fun() }
local function open_codediff(repo_path, range, view, on_done)
	local finished = false
	local autocmd_id
	local function finish(err)
		if finished then
			return
		end
		finished = true
		if autocmd_id then
			pcall(vim.api.nvim_del_autocmd, autocmd_id)
			autocmd_id = nil
		end
		view:finish()
		on_done(err)
	end

	-- CodeDiff opens its own tab, so close the temporary one.
	autocmd_id = vim.api.nvim_create_autocmd("User", {
		pattern = "CodeDiffOpen",
		once = true,
		callback = function()
			vim.schedule(function()
				finish(nil)
			end)
		end,
	})
	local ok, err = pcall(vim.api.nvim_win_call, view.win, function()
		vim.cmd("tcd " .. vim.fn.fnameescape(repo_path))
		vim.cmd("CodeDiff " .. range)
	end)
	if not ok then
		finish(tostring(err))
	end

	return {
		cancel = function()
			if finished then
				return
			end
			finished = true
			if autocmd_id then
				pcall(vim.api.nvim_del_autocmd, autocmd_id)
				autocmd_id = nil
			end
		end,
	}
end

---@param opts PullsDiffRangeOpenOptions
---@param on_done fun(err: string|nil)|nil
---@return { cancel: fun() }|nil
function M.open_diff_range(opts, on_done)
	local open_cmd, command_err = diff_open_command(opts.open_cmd)
	if not open_cmd then
		if on_done then
			on_done(command_err)
		end
		return nil
	end

	local root = tostring(opts.git_root or "")
	local base = vim.trim(tostring(opts.base_revision or ""))
	local head = vim.trim(tostring(opts.head_revision or ""))
	if root == "" or base == "" or head == "" then
		if on_done then
			on_done("Repository path, base revision, and head revision are required")
		end
		return nil
	end

	local range = base .. "..." .. head
	local command = open_cmd .. " " .. range
	logger.loginfo("actions.open_diff", { repo_path = root, command = command })

	local loading = require("atlas.ui.components.loading")
	local fetch_request
	local launch_request
	local completed = false
	local cancelled = false
	local view
	local function cancel()
		if cancelled or completed then
			return
		end
		cancelled = true
		if fetch_request then
			pcall(fetch_request.cancel)
			fetch_request = nil
		end
		if launch_request then
			pcall(launch_request.cancel)
			launch_request = nil
		end
		if view then
			view:finish()
		end
	end
	view = loading.open("Preparing diff...", cancel)

	---@param err string|nil
	local function complete(err)
		if completed or cancelled then
			return
		end
		completed = true
		fetch_request = nil
		launch_request = nil
		if on_done then
			on_done(err)
		end
	end

	---@param err string
	local function fail(err)
		view:finish()
		complete(err)
	end

	local function launch()
		if cancelled or completed then
			return
		end
		if open_cmd == "AtlasDiff" then
			-- The callback may finish before prepare() returns its request handle.
			local finished = false
			local request = require("atlas.pulls.diff.atlas.git").prepare({
				git_root = root,
				base_revision = base,
				head_revision = head,
				on_progress = function(message)
					view:update(message)
				end,
			}, function(prepared, err)
				finished = true
				launch_request = nil
				if cancelled then
					return
				end
				if not prepared then
					fail(tostring(err or "Unable to prepare diff"))
					return
				end
				view:finish()
				local ok, open_err = pcall(require("atlas.pulls.diff.atlas").open, {
					diff = prepared,
				})
				if not ok then
					open_err = tostring(open_err)
				end
				complete(open_err)
			end)
			if finished or cancelled then
				request.cancel()
			else
				launch_request = request
			end
			return
		end
		view:update("Opening diff...")
		if open_cmd == "CodeDiff" then
			launch_request = open_codediff(root, range, view, function(err)
				launch_request = nil
				complete(err)
			end)
			return
		end

		view:finish()
		complete(open_diffview(root, range))
	end
	local function start_launch()
		local ok, err = pcall(launch)
		if not ok then
			fail(tostring(err))
		end
	end

	if not opts.fetch_branches then
		start_launch()
		return { cancel = cancel }
	end

	view:update("Fetching remote branches...")
	local fetch_done = false
	local ok, request = pcall(opts.fetch_branches, function(err)
		fetch_done = true
		fetch_request = nil
		if cancelled or completed then
			return
		end
		if err then
			view:finish()
			complete(tostring(err))
			return
		end
		start_launch()
	end)
	if not ok then
		view:finish()
		complete(tostring(request))
	elseif fetch_done or completed or cancelled then
		if request then
			pcall(request.cancel)
		end
	else
		fetch_request = request
	end

	return { cancel = cancel }
end

---@param range string
function M.open_atlas_diff(range)
	local separator = range:find("...", 1, true)
	local base = separator and vim.trim(range:sub(1, separator - 1)) or ""
	local head = separator and vim.trim(range:sub(separator + 3)) or ""
	if base == "" or head == "" then
		vim.notify("[AtlasDiff] Expected an explicit base...head range", vim.log.levels.ERROR)
		return
	end
	M.open_diff_range({
		git_root = vim.fn.getcwd(),
		base_revision = base,
		head_revision = head,
		open_cmd = "AtlasDiff",
	}, function(err)
		if err then
			vim.notify("[AtlasDiff] " .. err, vim.log.levels.ERROR)
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

	local base_revision, head_revision, revision_err = checkout.pr_diff_revisions(pr)
	if not base_revision or not head_revision then
		local level = revision_err == "PR branch refs are missing" and "warn" or "error"
		footer.notify(level, tostring(revision_err))
		return
	end

	M.open_diff_range({
		git_root = resolved_path,
		base_revision = base_revision,
		head_revision = head_revision,
		fetch_branches = function(on_done)
			return checkout.fetch_pr_branches(pr, resolved_path, on_done)
		end,
	}, function(err)
		if err then
			logger.logerror("actions.open_diff failed", { pr_id = pr.id, error = tostring(err) })
			footer.notify("error", "Unable to open diff: " .. tostring(err))
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
