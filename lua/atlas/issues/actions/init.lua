local M = {}

local statusline = require("atlas.ui.statusline")

---@return IssuesProvider|nil
local function provider()
	return require("atlas.issues.state").provider
end

---@param action_id string
---@param issue Issue|nil
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil)|nil
function M.run_action(action_id, issue, source, on_done)
	local p = provider()
	local actions = p and p.capabilities.actions
	if not actions then
		return
	end

	actions.run(action_id, { issue = issue, source = source }, function(result, err)
		if err ~= nil then
			statusline.notify("error", tostring(err))
			if on_done then
				on_done(nil)
			end
			return
		end

		if result ~= nil and result.message ~= nil and result.message ~= "" then
			statusline.notify("info", tostring(result.message), 1200)
		end

		if result ~= nil and result.changed_issue_key ~= nil and result.changed_issue_key ~= "" then
			require("atlas.issues.ui.main.controller").refresh_issue(result.changed_issue_key)
		end

		if on_done then
			on_done(result)
		end
	end)
end

---@param issue Issue
---@param source "main"|"panel"|nil
---@param on_done fun(result: table|nil)|nil
function M.open_actions(issue, source, on_done)
	local p = provider()
	local actions = p and p.capabilities.actions
	if not actions then
		return
	end

	actions.open({ issue = issue, source = source }, function(result, err)
		if err ~= nil then
			statusline.notify("error", tostring(err))
			if on_done then
				on_done(nil)
			end
			return
		end

		if result ~= nil and result.changed_issue_key ~= nil and result.changed_issue_key ~= "" then
			require("atlas.issues.ui.main.controller").refresh_issue(result.changed_issue_key)
		end

		if result ~= nil and result.message ~= nil and result.message ~= "" then
			statusline.notify("info", tostring(result.message), 1200)
		end

		if on_done then
			on_done(result)
		end
	end)
end

---@param on_done fun(result: table|nil)|nil
function M.search(on_done)
	local p = provider()
	local search = p and p.capabilities.search
	if not search then
		return
	end

	search(function(result, err)
		if err ~= nil then
			statusline.notify("error", tostring(err))
			if on_done then
				on_done(nil)
			end
			return
		end

		if result ~= nil and result.message ~= nil and result.message ~= "" then
			statusline.notify("info", tostring(result.message), 1200)
		end

		if result ~= nil and result.changed_issue_key ~= nil and result.changed_issue_key ~= "" then
			require("atlas.issues.ui.main.controller").refresh_issue(result.changed_issue_key)
		end

		if on_done then
			on_done(result)
		end
	end)
end

---@param issue Issue
function M.open_in_browser(issue)
	M.run_action("browse_issue", issue, "main")
end

---@param issue Issue
function M.copy_key(issue)
	M.run_action("copy_issue_key", issue, "main")
end

---@param issue Issue
function M.copy_url(issue)
	M.run_action("copy_issue_url", issue, "main")
end

return M
