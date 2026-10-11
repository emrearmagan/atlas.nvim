local client = require("atlas.providers.gitlab.client")
local issue_mapper = require("atlas.issues.providers.gitlab.api.mapper")
local json = require("atlas.core.json")
local requests = require("atlas.core.requests")
local users_api = require("atlas.providers.gitlab.users")

local PARTICIPANTS_QUERY = [[
query($path: ID!, $iid: String!, $isMergeRequest: Boolean!) {
  project(fullPath: $path) {
    mergeRequest(iid: $iid) @include(if: $isMergeRequest) {
      participants(first: 100) { nodes { username name } }
      reviewers(first: 100) { nodes { username name } }
    }
    issue(iid: $iid) @skip(if: $isMergeRequest) {
      participants(first: 100) { nodes { username name } }
    }
  }
}
]]

local ISSUES_QUERY = [[
query($path: ID!) {
  project(fullPath: $path) {
    issues(first: 100, sort: UPDATED_DESC) {
      nodes { iid title state }
    }
  }
}
]]

local PULLS_QUERY = [[
query($path: ID!) {
  project(fullPath: $path) {
    mergeRequests(first: 100, sort: UPDATED_DESC) {
      nodes { iid title state draft }
    }
  }
}
]]

---@param candidates table[]
---@return AtlasCompletionItem[]
local function completion_items(candidates)
	local items, seen = {}, {}
	for _, user in ipairs(candidates) do
		if user.username and not seen[user.username] then
			seen[user.username] = true
			items[#items + 1] = {
				label = "@" .. user.username,
				insert_text = "@" .. user.username,
				filter_text = user.username .. " " .. user.name,
				detail = user.name,
			}
		end
	end
	return items
end

---@type AtlasCompletionSource
local users = {
	triggers = { "@" },

	complete = function(context, query, done)
		local issue_project, issue_iid
		if context.issue then
			issue_project, issue_iid = issue_mapper.parse_key(context.issue.key)
		end
		local project = context.repository
			or context.project
			or (context.pr and context.pr.repo_full_name)
			or issue_project
		if not project or project == "" then
			done(nil, "GitLab user completion requires a project")
			return
		end

		local target = project
		if context.pr then
			target = target .. "!" .. context.pr.id
		elseif issue_iid then
			target = target .. "#" .. issue_iid
		end
		local key = "gitlab:completion:users:" .. target .. ":" .. query
		local cached, found = client.get_memory_cache(key)
		if found then
			done(cached, nil)
			return
		end

		local scope = requests.new()
		local starts = {
			members = function(callback)
				return users_api.list_members(project, query, callback)
			end,
		}

		if context.pr or context.issue then
			starts.participants = function(callback)
				return client.graphql(PARTICIPANTS_QUERY, {
					path = project,
					iid = tostring(context.pr and context.pr.id or issue_iid),
					isMergeRequest = context.pr ~= nil,
				}, function(result, err)
					if err then
						callback(nil, err)
						return
					end
					local data = result and json.nilify(result.project)
					local item = data and json.nilify(context.pr and data.mergeRequest or data.issue)
					if not item then
						callback(nil, "Unable to fetch GitLab participants")
						return
					end

					local candidates = item.participants.nodes
					if context.pr then
						vim.list_extend(candidates, item.reviewers.nodes)
					end
					callback(candidates, nil)
				end, { action = "Complete participants", project_path = project })
			end
		end

		scope.all(starts, function(values, errors)
			local err = errors.members or errors.participants
			if err then
				done(nil, err)
				return
			end

			local candidates = values.participants or {}
			vim.list_extend(candidates, values.members)
			local items = completion_items(candidates)
			client.set_memory_cache(key, items)
			done(items, nil)
		end)
		return scope
	end,
}

---@type AtlasCompletionSource
local issues = {
	triggers = { "#" },

	complete = function(context, _, done)
		local project = context.repository
			or context.project
			or (context.pr and context.pr.repo_full_name)
			or (context.issue and issue_mapper.parse_key(context.issue.key))
		if not project or project == "" then
			done(nil, "GitLab issue completion requires a project")
			return
		end

		local key = "gitlab:completion:issues:" .. project
		local cached, found = client.get_memory_cache(key)
		if found then
			done(cached, nil)
			return
		end

		return client.graphql(ISSUES_QUERY, { path = project }, function(result, err)
			if err then
				done(nil, err)
				return
			end
			local data = result and json.nilify(result.project)
			if not data then
				done(nil, "Unable to fetch GitLab issues")
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local items = {}
			for _, item in ipairs(data.issues.nodes) do
				local reference = "#" .. item.iid
				local icon = icons.issues(item.state == "closed" and "success" or "issue")
				items[#items + 1] = {
					label = icon .. " " .. reference,
					insert_text = reference,
					filter_text = item.iid .. " " .. item.title,
					detail = item.title,
				}
			end
			client.set_memory_cache(key, items)
			done(items, nil)
		end, { action = "Complete issues", project_path = project })
	end,
}

---@type AtlasCompletionSource
local pulls = {
	triggers = { "!" },

	complete = function(context, _, done)
		local project = context.repository
			or context.project
			or (context.pr and context.pr.repo_full_name)
			or (context.issue and issue_mapper.parse_key(context.issue.key))
		if not project or project == "" then
			done(nil, "GitLab merge request completion requires a project")
			return
		end

		local key = "gitlab:completion:pulls:" .. project
		local cached, found = client.get_memory_cache(key)
		if found then
			done(cached, nil)
			return
		end

		return client.graphql(PULLS_QUERY, { path = project }, function(result, err)
			if err then
				done(nil, err)
				return
			end
			local data = result and json.nilify(result.project)
			if not data then
				done(nil, "Unable to fetch GitLab merge requests")
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local items = {}
			for _, item in ipairs(data.mergeRequests.nodes) do
				local reference = "!" .. item.iid
				local icon = item.draft and "draft_pr" or "pr"
				if item.state == "merged" then
					icon = "merged_pr"
				elseif item.state == "closed" then
					icon = "declined_pr"
				end
				items[#items + 1] = {
					label = icons.pulls(icon) .. " " .. reference,
					insert_text = reference,
					filter_text = item.iid .. " " .. item.title,
					detail = item.title,
				}
			end
			client.set_memory_cache(key, items)
			done(items, nil)
		end, { action = "Complete merge requests", project_path = project })
	end,
}

return {
	users = users,
	issues = issues,
	pulls = pulls,
}
