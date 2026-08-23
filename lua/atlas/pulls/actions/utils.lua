local M = {}

local git_checkout = require("atlas.core.git.checkout")
local icons = require("atlas.ui.shared.icons")
local logger = require("atlas.core.logger")
local core_notify = require("atlas.core.notify")

---@param context AtlasPullActionContext
---@return boolean
local function has_pr(context)
	return context.pr ~= nil
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
		label = icons.general("custom_action") .. "  " .. item.label,
		custom = true,
		is_available = has_pr,
		run = function(context, done)
			notify(context, "loading", string.format("Running %s...", item.label))
			local finished = false
			local function complete_custom(ok, message)
				if finished then
					return
				end
				finished = true
				vim.schedule(function()
					if ok == false then
						local err = message or (item.label .. " failed")
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
				output = require("atlas.ui.popups.live").create,
			}, complete_custom)
			if not ok then
				logger.logerror(string.format("Custom action '%s' failed: %s", item.label, tostring(err)))
				complete_custom(false, "Custom action failed: " .. tostring(err))
			end
		end,
	}
end

---@param context AtlasPullActionContext
---@return AtlasPullAction[]
function M.custom_actions(context)
	local actions = {}
	if not has_pr(context) then
		return actions
	end
	for _, item in ipairs((require("atlas.config").options.pulls or {}).custom_actions or {}) do
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

---@return { method: "merge"|"squash", delete_branch: boolean }
function M.merge_options()
	local config = require("atlas.config").options.pulls or {}
	return {
		method = config.default_merge_method or "merge",
		delete_branch = config.default_delete_branch == true,
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
