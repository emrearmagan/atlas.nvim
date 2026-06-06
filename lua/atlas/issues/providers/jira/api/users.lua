local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local cache = require("atlas.core.cache")
local config = require("atlas.issues.providers.jira.api.config")

---@param str string
---@return string
local function url_encode(str)
	return (str:gsub("([^%w%-_.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

---@param callback fun(user: IssueUser|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_myself(callback)
	local cache_key = "jira:myself:" .. (config.jira_config().email or "")
	local cached = cache.get(cache_key)
	if cached and cached.value then
		callback(cached.value, nil)
		return nil
	end

	return service.request("GET", "/myself", nil, function(result, err)
		if err or not result then
			callback(nil, err or "Empty response")
			return
		end

		local user = {
			display_name = tostring(result.displayName or ""),
		}
		-- Jira cloud uses `accountId` while Jira server uses `name`
		if config.jira_config().api_type == "server" then
			user.account_id = tostring(result.name or "")
		else
			user.account_id = tostring(result.accountId or "")
		end

		cache.set(cache_key, user, service.cache_ttl())
		callback(user, nil)
	end, {
		action = "Fetch current user",
	})
end

---@param opts { project: string|nil, issue_key: string|nil }
---@param query string|nil
---@param callback fun(users: IssueUser[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_assignable_users(opts, query, callback)
	opts = opts or {}
	local project = type(opts.project) == "string" and opts.project or ""
	local issue_key = type(opts.issue_key) == "string" and opts.issue_key or ""

	if project == "" and issue_key == "" then
		callback(nil, "Missing project or issue key")
		return nil
	end

	local is_server = config.jira_config().api_type == "server"

	local q = tostring(query or "")
	local params = {}
	if is_server then
		table.insert(params, "username=" .. url_encode(q))
	else
		table.insert(params, "query=" .. url_encode(q))
	end
	if issue_key ~= "" then
		table.insert(params, "issueKey=" .. url_encode(issue_key))
	end
	if project ~= "" then
		table.insert(params, "project=" .. url_encode(project))
	end
	local endpoint = "/user/assignable/search?" .. table.concat(params, "&")

	return service.request("GET", endpoint, nil, function(result, err)
		if err ~= nil or type(result) ~= "table" then
			callback(nil, err or "Empty response")
			return
		end

		local users = {}
		for _, raw in ipairs(result) do
			if type(raw) == "table" then
				local user = { display_name = tostring(raw.displayName or "") }
				if is_server then
					user.account_id = tostring(raw.name or "")
				else
					user.account_id = tostring(raw.accountId or "")
				end
				table.insert(users, user)
			end
		end

		callback(users, nil)
	end, {
		action = "Fetch assignable users",
		issue_key = issue_key,
		project = project,
		query = q,
	})
end

---@param opts { permissions?: string[]|nil, project_ids?: integer[]|nil, issue_ids?: integer[]|nil, account_id?: string|nil }
---@param callback fun(permissions: table<string, table<number, boolean>>|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_permissions_bulk(opts, callback)
	opts = opts or {}

	local permissions_list = {}
	for _, key in ipairs(opts.permissions or {}) do
		if type(key) == "string" then
			local value = vim.trim(key)
			if value ~= "" then
				table.insert(permissions_list, value)
			end
		end
	end

	if #permissions_list == 0 then
		callback(nil, "Missing permissions")
		return nil
	end

	local project_ids = {}
	for _, id in ipairs(opts.project_ids or {}) do
		local project_id = tonumber(id)
		if project_id ~= nil then
			table.insert(project_ids, project_id)
		end
	end

	local issue_ids = {}
	for _, id in ipairs(opts.issue_ids or {}) do
		local issue_id = tonumber(id)
		if issue_id ~= nil then
			table.insert(issue_ids, issue_id)
		end
	end

	local payload = {
		projectPermissions = {
			{
				permissions = permissions_list,
				projects = project_ids,
				issues = issue_ids,
			},
		},
	}

	if type(opts.account_id) == "string" and opts.account_id ~= "" then
		payload.accountId = opts.account_id
	end

	return service.request("POST", "/permissions/check", payload, function(result, err)
		if err ~= nil or type(result) ~= "table" then
			-- Handle 404 as a fallback since Jira server API don't have bulk permissions endpoint
			if err and err:find("HTTP 404", 1, true) == 1 then
				local fallback = {}
				for _, key in ipairs(permissions_list) do
					fallback[key] = {}
					for _, pid in ipairs(project_ids) do
						fallback[key][pid] = true
					end
					for _, iid in ipairs(issue_ids) do
						fallback[key][iid] = true
					end
				end
				callback(fallback, nil)
				return
			end
			callback(nil, err or "Empty response")
			return
		end

		---@type table<string, table<number, boolean>>
		local permissions = {}
		for _, entry in ipairs(result.projectPermissions or {}) do
			local permission_key = type(entry.permission) == "string" and entry.permission or ""
			if permission_key ~= "" then
				permissions[permission_key] = permissions[permission_key] or {}
				for _, project_id in ipairs(entry.projects or {}) do
					local id_num = tonumber(project_id)
					if id_num ~= nil then
						permissions[permission_key][id_num] = true
					end
				end
			end
		end

		callback(permissions, nil)
	end, {
		action = "Fetch bulk permissions",
		permissions = permissions_list,
		project_count = #project_ids,
		issue_count = #issue_ids,
		account_id = opts.account_id,
	})
end

---@param issue_key string
---@param account_id string|nil
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.assign_issue(issue_key, account_id, callback)
	if type(issue_key) ~= "string" or issue_key == "" then
		callback(false, "Missing issue key")
		return nil
	end

	local normalized_account_id = nil
	if type(account_id) == "string" and account_id ~= "" then
		normalized_account_id = account_id
	end

	local endpoint = string.format("/issue/%s/assignee", issue_key)
	local payload = {}
	if config.jira_config().api_type == "server" then
		payload.name = normalized_account_id or vim.NIL
	else
		payload.accountId = normalized_account_id or vim.NIL
	end

	return service.request("PUT", endpoint, payload, function(_, err)
		if err ~= nil then
			callback(false, err)
			return
		end

		callback(true, nil)
	end, {
		action = "Assign issue",
		issue_key = issue_key,
		unassign = normalized_account_id == nil,
	})
end

---@param issue_key string
---@param account_id string
---@param callback fun(ok: boolean, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.change_reporter(issue_key, account_id, callback)
	if type(issue_key) ~= "string" or issue_key == "" then
		callback(false, "Missing issue key")
		return nil
	end

	if type(account_id) ~= "string" or account_id == "" then
		callback(false, "Missing account id")
		return nil
	end

	local endpoint = string.format("/issue/%s", issue_key)
	local payload = { fields = { reporter = {} } }
	if config.jira_config().api_type == "server" then
		payload.fields.reporter.name = account_id
	else
		payload.fields.reporter.accountId = account_id
	end

	return service.request("PUT", endpoint, payload, function(_, err)
		if err ~= nil then
			callback(false, err)
			return
		end

		callback(true, nil)
	end, {
		action = "Change reporter",
		issue_key = issue_key,
	})
end

return M
