local client = require("atlas.providers.github.client")
local issue_mapper = require("atlas.issues.providers.github.api.mapper")
local json = require("atlas.core.json")
local mapper = require("atlas.providers.github.mapper")

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

---@param users table[]
---@return AtlasCompletionItem[]
local function completion_items(users)
	local items, seen = {}, {}
	for _, raw in ipairs(users) do
		local user = mapper.to_user(raw)
		if user and user.username and user.username ~= "" and not seen[user.username] then
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
return {
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
