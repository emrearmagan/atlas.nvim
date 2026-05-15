local M = {}

local service = require("atlas.issues.providers.jira.api.service")

---@param issue_key string
---@param callback fun(transitions: IssueTransition[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_transitions(issue_key, callback)
	return service.request("GET", string.format("/issue/%s/transitions", issue_key), nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		---@type IssueTransition[]
		local transitions = {}
		for _, t in ipairs(result.transitions or {}) do
			local to = t.to or {}
			local category = to.statusCategory or {}
			table.insert(transitions, {
				id = tostring(t.id or ""),
				name = tostring(t.name or ""),
				to_status_id = to.id and tostring(to.id) or nil,
				to_status_name = to.name and tostring(to.name) or nil,
				to_status_category = category.key and tostring(category.key) or nil,
				to_status_color = category.colorName and tostring(category.colorName) or nil,
			})
		end

		callback(transitions, nil)
	end, {
		action = "Fetch transitions",
		issue_key = issue_key,
	})
end

---@param issue_key string
---@param transition_id string|number
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.transition_issue(issue_key, transition_id, callback)
	local id = tostring(transition_id or "")
	if id == "" then
		callback(false, "Missing transition id")
		return nil
	end

	return service.request("POST", string.format("/issue/%s/transitions", issue_key), { transition = { id = id } }, function(_, err)
		if err then
			callback(false, err)
			return
		end
		callback(true, nil)
	end, {
		action = "Transition issue",
		issue_key = issue_key,
		transition_id = id,
	})
end

return M
