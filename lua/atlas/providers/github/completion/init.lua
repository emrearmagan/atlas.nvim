local client = require("atlas.providers.github.client")
local issue_mapper = require("atlas.issues.providers.github.api.mapper")
local json = require("atlas.core.json")
local users_api = require("atlas.providers.github.users")

local USERS_QUERY = [[
query($owner: String!, $repo: String!, $search: String!, $number: Int!, $fetchParticipants: Boolean!) {
  repository(owner: $owner, name: $repo) {
    mentionableUsers(first: 50, query: $search) {
      nodes { id login name }
    }
    item: issueOrPullRequest(number: $number) @include(if: $fetchParticipants) {
      ... on Issue {
        participants(first: 100) {
          nodes { id login name }
        }
      }
      ... on PullRequest {
        participants(first: 100) {
          nodes { id login name }
        }
        reviewRequests(first: 100) {
          nodes { requestedReviewer { ... on User { id login name } } }
        }
      }
    }
  }
}
]]

local REFERENCES_QUERY = [[
query($search: String!) {
  search(query: $search, type: ISSUE, first: 100) {
    nodes {
      ... on %s { number title state %s }
    }
  }
}
]]

---@param users table[]
---@return AtlasCompletionItem[]
local function completion_items(users)
	local items, seen = {}, {}
	for _, raw in ipairs(users) do
		local user = users_api.to_user(raw)
		if user and user.username and not seen[user.username] then
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
		local repository = context.repository or (context.pr and context.pr.repo_full_name)
		local number = context.pr and context.pr.id
		if context.issue then
			local slug
			slug, number = issue_mapper.parse_key(context.issue.key)
			repository = repository or slug
		end

		local owner, repo = (repository or ""):match("^([^/]+)/([^/]+)$")
		if not owner then
			done(nil, "GitHub user completion requires a repository")
			return
		end

		local scope = repository .. (number and "#" .. number or "")
		local key = "github:completion:users:" .. scope .. ":" .. query
		local cached, found = client.get_mem(key)
		if found then
			done(cached, nil)
			return
		end

		local args = {
			"api",
			"graphql",
			"-f",
			"query=" .. USERS_QUERY,
			"-f",
			"owner=" .. owner,
			"-f",
			"repo=" .. repo,
			"-f",
			"search=" .. query,
			"-F",
			"number=" .. tostring(number or 0),
			"-F",
			"fetchParticipants=" .. tostring(number ~= nil),
		}
		return client.gh(args, function(result, err)
			if err then
				done(nil, err)
				return
			end
			local data = result and result.data and json.nilify(result.data.repository)
			if not data then
				done(nil, "Unable to fetch GitHub mentionable users")
				return
			end

			local candidates = number and data.item.participants.nodes or {}
			if context.pr then
				for _, request in ipairs(data.item.reviewRequests.nodes) do
					local reviewer = json.nilify(request.requestedReviewer)
					if reviewer and reviewer.login then
						candidates[#candidates + 1] = reviewer
					end
				end
			end
			vim.list_extend(candidates, data.mentionableUsers.nodes)
			local items = completion_items(candidates)
			client.set_mem(key, items)
			done(items, nil)
		end, { action = "Complete mentionable users", repo = repository })
	end,
}

---@param item { state: string, isDraft?: boolean }
---@param is_pull boolean
---@return string, string
local function reference_icon(item, is_pull)
	local icons = require("atlas.ui.shared.icons")
	if not is_pull then
		return icons.issues(item.state == "CLOSED" and "success" or "issue")
	end
	if item.state == "MERGED" then
		return icons.pulls("merged_pr")
	end
	if item.state == "CLOSED" then
		return icons.pulls("declined_pr")
	end
	return icons.pulls(item.isDraft and "draft_pr" or "pr")
end

---@param kind "issues"|"pulls"
---@return AtlasCompletionSource
local function reference_source(kind)
	local is_pull = kind == "pulls"
	local query = REFERENCES_QUERY:format(is_pull and "PullRequest" or "Issue", is_pull and "isDraft" or "")
	return {
		triggers = { "#" },

		complete = function(context, _, done)
			local repository = context.repository
				or (context.pr and context.pr.repo_full_name)
				or (context.issue and issue_mapper.parse_key(context.issue.key))
			if not repository or repository == "" then
				done(nil, "GitHub reference completion requires a repository")
				return
			end

			local key = "github:completion:" .. kind .. ":" .. repository
			local cached, found = client.get_mem(key)
			if found then
				done(cached, nil)
				return
			end

			local args = {
				"api",
				"graphql",
				"-f",
				"query=" .. query,
				"-f",
				"search=repo:" .. repository .. " is:" .. (is_pull and "pr" or "issue") .. " sort:updated-desc",
			}

			return client.gh(args, function(result, err)
				if err or not result then
					done(nil, err or ("Unable to fetch GitHub " .. kind))
					return
				end

				local items = {}
				for _, item in ipairs(result.data.search.nodes) do
					local reference = "#" .. item.number
					items[#items + 1] = {
						label = reference_icon(item, is_pull) .. " " .. reference,
						insert_text = reference,
						filter_text = item.number .. " " .. item.title,
						detail = item.title,
					}
				end
				client.set_mem(key, items)
				done(items, nil)
			end, { action = "Complete " .. kind, repo = repository })
		end,
	}
end

return {
	users = users,
	issues = reference_source("issues"),
	pulls = reference_source("pulls"),
}
