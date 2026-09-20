local M = {}

local config = require("atlas.config")
local git_checkout = require("atlas.core.git.checkout")
local live = require("atlas.ui.popups.live")
local logger = require("atlas.core.logger")
local core_notify = require("atlas.core.notify")

---@param context AtlasPullActionContext
---@return boolean, string|nil
local function has_pr(context)
	if not context.pr then
		return false, "No PR selected"
	end
	return true
end

---@param context AtlasPullActionContext
---@param level "loading"|"success"|"info"|"warn"|"error"
---@param message string
---@param duration integer|nil
local function notify(context, level, message, duration)
	if context.notify then
		context.notify(level, message, duration)
		return
	end
	core_notify.show(level, message, { timeout = duration })
end

---@param item AtlasPullsCustomAction
---@return AtlasPullAction
local function custom_action(item)
	return {
		id = item.id,
		label = item.label,
		icon = item.icon,
		is_available = has_pr,
		run = function(context, done)
			notify(context, "loading", string.format("Running %s...", item.label))
			local finished = false
			local function log_failure(err)
				local pr = context.pr
				logger.logerror("Custom pull request action failed", {
					action_id = item.id,
					action = item.label,
					repo = pr and pr.repo_full_name or nil,
					pr_id = pr and pr.id or nil,
					error = err,
				})
			end
			local function complete_custom(ok, message)
				if finished then
					return
				end
				finished = true
				vim.schedule(function()
					if ok == false then
						local err = message or (item.label .. " failed")
						log_failure(err)
						notify(context, "error", err)
						done(nil, err)
						return
					end
					local result = message or (item.label .. " done")
					notify(context, "success", result)
					done({ changed_pr = false, message = result }, nil)
				end)
			end
			local pr = assert(context.pr)
			local repo_path = git_checkout.resolve_repo_path_for_pr(pr, {
				require_git = false,
				require_existing = false,
			})
			local ok, err = pcall(item.run, pr, {
				repo_path = repo_path,
				pr = pr,
				user = context.current_user,
				output = live.create,
			}, complete_custom)
			if not ok then
				local message = "Custom action failed: " .. tostring(err)
				if finished then
					log_failure(message)
				else
					complete_custom(false, message)
				end
			end
		end,
	}
end

---@return AtlasPullAction[]
function M.custom_actions()
	local actions = {}
	for _, item in ipairs((config.options.pulls or {}).custom_actions or {}) do
		if
			type(item) == "table"
			and type(item.id) == "string"
			and type(item.label) == "string"
			and type(item.run) == "function"
		then
			table.insert(actions, custom_action(item))
		end
	end
	return actions
end

---@param id string
---@return AtlasPullAction|nil
function M.find_custom_action(id)
	for _, action in ipairs(M.custom_actions()) do
		if action.id == id then
			return action
		end
	end
end

---@return { method: "merge"|"squash", delete_branch: boolean }
function M.merge_options()
	local options = config.options.pulls or {}
	return {
		method = options.default_merge_method or "merge",
		delete_branch = options.default_delete_branch == true,
	}
end

M.copy_id = {
	id = "copy_id",
	label = "Copy ID",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		vim.fn.setreg("+", tostring(pr.id))
		notify(context, "success", string.format("Copied #%s to clipboard", tostring(pr.id)), 1200)
		done({ changed_pr = false, message = "Copied ID" }, nil)
	end,
}

M.copy_url = {
	id = "copy_url",
	label = "Copy URL",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		local url = pr.link and pr.link.html
		if not url or url == "" then
			notify(context, "warn", "No URL available")
			done(nil, "No URL available")
			return
		end
		vim.fn.setreg("+", url)
		notify(context, "success", "Copied URL to clipboard", 1200)
		done({ changed_pr = false, message = "Copied URL" }, nil)
	end,
}

M.open_in_browser = {
	id = "open_in_browser",
	label = "Open in browser",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		local url = pr.link and pr.link.html
		if not url or url == "" then
			notify(context, "warn", "No URL available")
			done(nil, "No URL available")
			return
		end
		vim.ui.open(url)
		notify(context, "info", "Opened in browser")
		done({ changed_pr = false, message = "Opened in browser" }, nil)
	end,
}

M.has_pr = has_pr
M.notify = notify

return M
