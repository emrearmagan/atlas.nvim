local M = {}

local footer = require("atlas.ui.components.footer")
local checkout = require("atlas.core.git.checkout")

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
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.open_pipelines(pr, on_done)
	local p = provider()
	if p == nil or type(p.fetch_pipelines) ~= "function" then
		local err = "Pipelines are not supported by this provider"
		footer.notify("warn", err)
		on_done(nil, err)
		return nil
	end

	require("atlas.pulls.ui.pipelines").open(pr)
	local message = "Opened Pipelines"
	footer.notify("success", message, 1200)
	on_done({ changed_pr = false, message = message }, nil)
	return nil
end

local PROVIDER_ACTIONS_MODULES = {
	github = "atlas.pulls.providers.github.actions",
	gitlab = "atlas.pulls.providers.gitlab.actions",
	bitbucket = "atlas.pulls.providers.bitbucket.actions",
}

---@class PullsRunActionOptions
---@field source "main"|"panel"|"diff"|nil
---@field current_user PullsUser|nil
---@field notify fun(level: "loading"|"success"|"info"|"warn"|"error", message: string, duration: integer|nil)|nil

---@param pr PullRequest
---@param action_id string
---@return boolean
function M.is_action_available(pr, action_id)
	local mod_path = PROVIDER_ACTIONS_MODULES[pr.provider]
	if not mod_path then
		return false
	end
	local registry = require(mod_path .. ".registry")
	local action = registry.find(action_id)
	return action ~= nil and action.is_available({ pr = pr, source = nil }) == true
end

---@param pr PullRequest
---@param action_id string
---@param opts PullsRunActionOptions|nil
---@param on_done fun(result: PullsActionResult|nil, err: string|nil)|nil
function M.run_action(pr, action_id, opts, on_done)
	opts = opts or {}
	local mod_path = PROVIDER_ACTIONS_MODULES[pr.provider]
	if not mod_path then
		if on_done then
			on_done(nil, "Provider does not support actions")
		end
		return
	end
	local mod = require(mod_path)
	mod.run(action_id, {
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
			footer.notify(level or "error", "Unable to open diff: " .. tostring(err))
		end
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
