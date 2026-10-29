local M = {}

local config = require("atlas.config")
local git_checkout = require("atlas.core.git.checkout")
local console = require("atlas.ui.console")
local logger = require("atlas.core.logger")
local notify = require("atlas.core.notify")

---@param context AtlasPullActionContext
---@return boolean, string|nil
local function has_pr(context)
	if not context.pr then
		return false, "No PR selected"
	end
	return true
end

---@param item AtlasPullsCustomAction
---@return AtlasPullAction
local function custom_action(item)
	local confirm = item.confirm
	return {
		id = item.id,
		label = item.label,
		icon = item.icon,
		confirm = type(confirm) == "function" and function(context)
			return confirm(assert(context.pr))
		end or confirm,
		is_available = has_pr,
		run = function(context, done)
			notify.loading(string.format("Running %s...", item.label))
			local finished = false
			---@type AtlasConsoleOutput|nil
			local output
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
				if output then
					if ok == false and message then
						output:write(message .. "\n")
					end
					output:finish(ok == false and 1 or 0)
				end
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
					done({ changed_pr = false }, nil)
				end)
			end
			local pr = assert(context.pr)
			return git_checkout.resolve_repo_path_for_pr(pr, {
				require_existing = false,
			}, function(repo_path)
				local ok, err = pcall(item.run, pr, {
					repo_path = repo_path,
					pr = pr,
					user = context.current_user,
					write = function(text)
						if finished then
							return
						end
						if not output then
							output = console.start(item.label, repo_path)
							console.open()
						end
						output:write(text)
					end,
				}, complete_custom)
				if not ok then
					local message = "Custom action failed: " .. tostring(err)
					if finished then
						log_failure(message)
					else
						complete_custom(false, message)
					end
				end
			end)
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

M.copy_id = {
	id = "copy_id",
	label = "Copy ID",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		vim.fn.setreg("+", tostring(pr.id))
		notify.success(string.format("Copied #%s to clipboard", tostring(pr.id)), { timeout = 1200 })
		done({ changed_pr = false }, nil)
	end,
}

M.copy_url = {
	id = "copy_url",
	label = "Copy URL",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		local url = pr.link.html
		if url == "" then
			notify.warn("No URL available")
			done(nil, "No URL available")
			return
		end
		vim.fn.setreg("+", url)
		notify.success("Copied URL to clipboard", { timeout = 1200 })
		done({ changed_pr = false }, nil)
	end,
}

M.open_in_browser = {
	id = "open_in_browser",
	label = "Open in browser",
	hidden = true,
	is_available = has_pr,
	run = function(context, done)
		local pr = assert(context.pr)
		local url = pr.link.html
		if url == "" then
			notify.warn("No URL available")
			done(nil, "No URL available")
			return
		end
		vim.ui.open(url)
		notify.info("Opened in browser")
		done({ changed_pr = false }, nil)
	end,
}

M.has_pr = has_pr

return M
