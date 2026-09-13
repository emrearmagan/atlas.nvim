-- https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/updates/list?view=azure-devops-rest-7.1

local M = {}

local mapper = require("atlas.issues.providers.azure.api.mapper")
local requests = require("atlas.core.requests")
local service = require("atlas.pulls.providers.azure.api.service")

---@param issue Issue
---@param opts IssuesFetchOpts|nil
---@param on_done fun(entries: IssueActivityEntry[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch(issue, opts, on_done)
	---@cast issue AzureIssue
	opts = opts or {}
	local cache_key = "workitem:" .. issue.key .. ":history"
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/%s/_apis/wit/workItems/%d/updates", service.url_encode(issue.project), issue.id)
	local scope = requests.new()
	local entries = {}
	local function fetch_page(skip)
		local query = service.build_query({ ["$top"] = 100, ["$skip"] = skip })
		scope.run(function(done)
			return service.request("GET", endpoint .. query, nil, done, {
				action = "Fetch work item history",
				issue_key = issue.key,
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			vim.list_extend(entries, mapper.to_history(result.value))
			if #result.value == 100 then
				fetch_page(skip + 100)
				return
			end
			service.set_cache(cache_key, entries)
			on_done(entries, nil)
		end)
	end
	fetch_page(0)
	return scope
end

return M
