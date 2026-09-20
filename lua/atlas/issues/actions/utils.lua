local M = {}

local config = require("atlas.config")
local live = require("atlas.ui.popups.live")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")

---@param context AtlasIssueActionContext
---@return boolean, string|nil
local function has_issue(context)
	if not context.issue or tostring(context.issue.key or "") == "" then
		return false, "No issue selected"
	end
	return true
end

---@param item AtlasIssuesCustomAction
---@return AtlasIssueAction
local function custom_action(item)
	return {
		id = item.id,
		label = item.label,
		icon = item.icon,
		is_available = has_issue,
		run = function(context, done)
			notify.loading(string.format("Running %s...", item.label))
			local finished = false
			local function log_failure(err)
				logger.logerror("Custom issue action failed", {
					action_id = item.id,
					action = item.label,
					issue_key = context.issue and context.issue.key or nil,
					error = err,
				})
			end
			local function complete(ok, message)
				if finished then
					return
				end
				finished = true
				vim.schedule(function()
					if ok == false then
						local err = message or (item.label .. " failed")
						log_failure(err)
						notify.error(err)
						done(nil, err)
						return
					end
					local result = message or (item.label .. " done")
					notify.success(result)
					done({ issue_key = context.issue and context.issue.key or nil }, nil)
				end)
			end

			local ok, err = pcall(item.run, context.issue, {
				issue = context.issue,
				user = context.current_user,
				output = live.create,
			}, complete)
			if not ok then
				local message = "Custom action failed: " .. tostring(err)
				if finished then
					log_failure(message)
				else
					complete(false, message)
				end
			end
		end,
	}
end

---@return AtlasIssueAction[]
function M.custom_actions()
	local actions = {}
	for _, item in ipairs((config.options.issues or {}).custom_actions or {}) do
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
---@return AtlasIssueAction|nil
function M.find_custom_action(id)
	for _, action in ipairs(M.custom_actions()) do
		if action.id == id then
			return action
		end
	end
end

M.browse_issue = {
	id = "browse_issue",
	label = "Open Issue In Browser",
	hidden = true,
	is_available = has_issue,
	run = function(context, done)
		local url = tostring(context.issue and context.issue.url or "")
		if url == "" then
			notify.warn("No URL available")
			done(nil, "No URL available")
			return
		end
		vim.ui.open(url)
		notify.info("Opened in browser")
		done(nil, nil)
	end,
}

M.copy_issue_key = {
	id = "copy_issue_key",
	label = "Copy Issue Key",
	hidden = true,
	is_available = has_issue,
	run = function(context, done)
		local key = tostring(context.issue and context.issue.key or "")
		vim.fn.setreg("+", key)
		vim.fn.setreg('"', key)
		notify.success("Copied issue key", { timeout = 1200 })
		done(nil, nil)
	end,
}

M.copy_issue_url = {
	id = "copy_issue_url",
	label = "Copy Issue URL",
	hidden = true,
	is_available = has_issue,
	run = function(context, done)
		local url = tostring(context.issue and context.issue.url or "")
		if url == "" then
			notify.warn("No URL available")
			done(nil, "No URL available")
			return
		end
		vim.fn.setreg("+", url)
		vim.fn.setreg('"', url)
		notify.success("Copied issue URL", { timeout = 1200 })
		done(nil, nil)
	end,
}

return M
