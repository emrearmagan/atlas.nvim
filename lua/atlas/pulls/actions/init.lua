local M = {}

local statusline = require("atlas.ui.statusline")
local checkout = require("atlas.core.git.checkout")
local md_editor = require("atlas.ui.popups.editor")

---@class PullsActionResult
---@field changed_pr boolean
---@field message string|nil

---@return PullsProvider|nil
local function provider()
	return require("atlas.pulls.state").provider
end

---@param pr PullRequest
function M.copy_id(pr)
	vim.fn.setreg("+", tostring(pr.id))
	statusline.notify("success", string.format("Copied #%s to clipboard", tostring(pr.id)), 1200)
end

---@param pr PullRequest
function M.copy_url(pr)
	local url = pr.link and pr.link.html
	if url == nil or url == "" then
		statusline.notify("warn", "No URL available")
		return
	end
	vim.fn.setreg("+", url)
	statusline.notify("success", "Copied URL to clipboard", 1200)
end

---@param pr PullRequest
function M.open_in_browser(pr)
	local url = pr.link and pr.link.html
	if url == nil or url == "" then
		statusline.notify("warn", "No URL available")
		return
	end
	vim.ui.open(url)
	statusline.notify("info", "Opened in browser")
end

---@param pr PullRequest
---@param on_done fun(ok: boolean)
function M.edit_title(pr, on_done)
	local p = provider()
	local core = p and p.capabilities.core
	if not core or not core.update_title then
		statusline.notify("warn", "Editing the PR title is not supported for this provider")
		on_done(false)
		return
	end

	md_editor.open({
		key = "pr-title-edit-" .. tostring(pr.id),
		title = " Edit Title ",
		width_ratio = 0.5,
		height_ratio = 0.12,
		initial_text = pr.title or "",
		on_save = function(text)
			local title = text and vim.trim(text) or ""
			if title == "" or title == pr.title then
				on_done(false)
				return
			end
			statusline.notify("loading", "Updating title...")
			core.update_title(pr, title, function(ok, err)
				if err or ok == false then
					statusline.notify("error", "Title update failed: " .. tostring(err or "Unknown error"))
					on_done(false)
					return
				end
				pr.title = title
				statusline.notify("success", "Title updated", 1200)
				on_done(true)
			end)
		end,
	})
end

---@param pr PullRequest
---@param buf integer
function M.show_details(pr, buf)
	local info_popup = require("atlas.ui.popups.info")
	local lines, highlights = require("atlas.pulls.ui.popup").content(pr)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = buf,
	})
end

---@param pr PullRequest
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.open_pipelines(pr, on_done)
	local p = provider()
	if p == nil or p.capabilities.pipelines == nil then
		local err = "Pipelines are not supported by this provider"
		statusline.notify("warn", err)
		on_done(nil, err)
		return nil
	end

	require("atlas.pulls.ui.pipelines").open(pr)
	local message = "Opened Pipelines"
	statusline.notify("success", message, 1200)
	on_done({ changed_pr = false, message = message }, nil)
	return nil
end

---@class PullsRunActionOptions
---@field source "main"|"panel"|"diff"|nil
---@field current_user PullsUser|nil
---@field notify fun(level: "loading"|"success"|"info"|"warn"|"error", message: string, duration: integer|nil)|nil

---@param pr PullRequest
---@param action_id string
---@return boolean
function M.is_action_available(pr, action_id)
	local provider_module = require("atlas.providers").load(pr.provider, "pulls")
	local actions = provider_module and provider_module.capabilities.actions
	if actions == nil then
		return false
	end
	return actions.is_available(action_id, { pr = pr, source = nil })
end

---@param pr PullRequest
---@param action_id string
---@param opts PullsRunActionOptions|nil
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
function M.run_action(pr, action_id, opts, on_done)
	opts = opts or {}
	local provider_module = require("atlas.providers").load(pr.provider, "pulls")
	local actions = provider_module and provider_module.capabilities.actions
	if not actions then
		if on_done then
			on_done(nil, "Provider does not support actions")
		end
		return
	end
	actions.run(action_id, {
		pr = pr,
		source = opts.source,
		current_user = opts.current_user,
		notify = opts.notify,
	}, function(result, err)
		if opts.source ~= nil and opts.source ~= "diff" and result ~= nil and result.changed_pr then
			require("atlas.pulls.ui.main.controller").refresh_pr(pr)
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
	local actions = p and p.capabilities.actions
	if not actions then
		return
	end
	actions.open(
		{ pr = pr, source = source, current_user = require("atlas.pulls.state").current_user },
		function(result)
			if result ~= nil and result.changed_pr then
				local controller = require("atlas.pulls.ui.main.controller")
				controller.refresh_pr(pr)
			end
			if on_done then
				on_done(result)
			end
		end
	)
end

---@param opts PullsDiffOpenOptions
---@param on_done fun(err: string|nil)|nil
---@return { cancel: fun() }|nil
function M.open_diff_range(opts, on_done)
	return require("atlas.pulls.diff").open_range(opts, on_done)
end

---@param value string
function M.open_atlas_diff(value)
	require("atlas.pulls.diff").open_argument(value)
end

---@param pr PullRequest
---@return { cancel: fun() }|nil
function M.open_diff(pr)
	local pulls_state = require("atlas.pulls.state")
	return require("atlas.pulls.diff").open_pr({
		pr = pr,
		provider = pulls_state.provider,
		current_user = pulls_state.current_user,
	}, function(err, level)
		if err then
			statusline.notify(level or "error", "Unable to open diff: " .. tostring(err))
		end
	end)
end

---@param pr PullRequest
function M.checkout(pr)
	statusline.notify("loading", string.format("Checking out PR #%s", tostring(pr.id or "")))
	checkout.checkout_pr(pr, function(_, err)
		vim.schedule(function()
			if err then
				statusline.notify("error", string.format("Checkout failed: %s", tostring(err)))
				return
			end
			statusline.notify("success", string.format("Checked out PR #%s", tostring(pr.id or "")))
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
	local search = p and p.capabilities.search
	if not search then
		return
	end
	search()
end

return M
