local mapper = require("atlas.issues.providers.forge.api.mapper")
local mapping = require("atlas.providers.forge.mapping")
local request_scope = require("atlas.core.requests")

local M = {}

---@param service ForgeService
---@param issues ForgeIssuesApi
function M.new(service, issues)
	local provider_name = service.name
	local api = {}

	---@param issue GiteaIssue|ForgejoIssue
	---@param opts IssuesFetchOpts|nil
	---@param on_done fun(conversation: IssueConversation|nil, err: string|nil)
	---@return { cancel: fun() }|nil
	function api.list(issue, opts, on_done)
		local owner, repo = issue.repo_full_name:match("^([^/]+)/([^/]+)$")
		local number = issue.number
		if not owner or not number then
			on_done(nil, "Invalid " .. provider_name .. " issue key")
			return nil
		end
		local path = string.format(
			"/repos/%s/%s/issues/%d/timeline",
			service.url_encode(owner),
			service.url_encode(repo),
			number
		)

		local requests = request_scope.new()
		requests.all({
			timeline = function(done)
				return service.fetch_all(path, nil, nil, done)
			end,
			details = function(done)
				return issues.get(issue, opts, done)
			end,
		}, function(values, errors)
			if errors.timeline then
				on_done(nil, errors.timeline)
				return
			end

			local result = { comments = {}, activities = {} }
			for _, raw in ipairs(values.timeline) do
				local raw_type = raw.type
				if raw_type == "comment" then
					table.insert(result.comments, mapper.to_comment(raw, issue))
				else
					table.insert(result.activities, mapper.to_timeline_entry(raw))
				end
			end

			local details = values.details
			result.description = details
				and {
					id = "description",
					url = issue.url,
					author = issue.reporter,
					author_roles = issue.reporter
						and mapping.author_roles(issue.reporter.username, issue.reporter.username, issue.repo_full_name),
					body = details.description,
					created_at = issue.created_at or "",
					reactions = details.reactions,
				}
			-- Timeline responses omit reaction counts; loading them requires one request per comment.
			on_done(result, errors.details)
		end)
		return requests
	end

	return api
end

return M
