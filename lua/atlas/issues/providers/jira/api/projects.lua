local M = {}

local service = require("atlas.issues.providers.jira.api.service")
local normalizer = require("atlas.issues.providers.jira.api.mapper")

---@class JiraProjectGroup
---@field category table|nil
---@field projects IssueProject[]

---@param opts { maxResults?: integer, total?: integer, status?: string, query?: string }|nil
---@param callback fun(groups: JiraProjectGroup[]|nil, err: string|nil)
---@return { job_id: integer, cancel: fun() }|nil
function M.get_projects(opts, callback)
	opts = opts or {}
	local max_results = math.max(1, tonumber(opts.maxResults) or 20)
	local total_pages = math.max(1, tonumber(opts.total) or 1)
	local status = tostring(opts.status or "live")
	local query = type(opts.query) == "string" and opts.query or ""

	local projects = {}
	local pages_loaded = 0
	local active_handle = nil
	local cancelled = false

	local function cancel_all()
		cancelled = true
		if active_handle and active_handle.cancel then
			active_handle.cancel()
		end
	end

	local function build_groups(items)
		---@type JiraProjectGroup[]
		local groups = {}
		local index_by_key = {}

		for _, project in ipairs(items) do
			local category = project.category
			local category_key = "uncategorized"
			if category ~= nil and category.id ~= "" then
				category_key = category.id
			end

			local group_idx = index_by_key[category_key]
			if group_idx == nil then
				group_idx = #groups + 1
				index_by_key[category_key] = group_idx
				groups[group_idx] = { category = category, projects = {} }
			end

			table.insert(groups[group_idx].projects, project)
		end

		return groups
	end

	local function fetch_page(start_at)
		if cancelled then
			return
		end

		local endpoint = string.format(
			"/project/search?maxResults=%d&startAt=%d&status=%s",
			max_results,
			start_at,
			vim.fn.escape(status, "&=?")
		)
		if query ~= "" then
			endpoint = endpoint .. "&query=" .. vim.fn.escape(query, "&=?")
		end

		active_handle = service.request("GET", endpoint, nil, function(result, err)
			if cancelled then
				return
			end

			if err or not result then
				callback(nil, err or "Empty response")
				return
			end

			for _, raw in ipairs(result.values or {}) do
				local project = normalizer.to_project(raw)
				if project then
					table.insert(projects, project)
				end
			end

			pages_loaded = pages_loaded + 1
			if result.isLast == true or pages_loaded >= total_pages then
				callback(build_groups(projects), nil)
				return
			end

			local next_start = tonumber(result.startAt) or start_at
			fetch_page(next_start + max_results)
		end, {
			action = "Fetch projects",
			status = status,
			query = query,
			max_results = max_results,
			start_at = start_at,
		})
	end

	fetch_page(0)

	return {
		job_id = active_handle and active_handle.job_id or -1,
		cancel = cancel_all,
	}
end

return M
