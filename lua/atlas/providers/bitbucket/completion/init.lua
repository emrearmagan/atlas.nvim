local service = require("atlas.providers.bitbucket.client")
local json = require("atlas.core.json")

---@param users table[]
---@param query string
---@return AtlasCompletionItem[]
local function completion_items(users, query)
	local items, seen = {}, {}
	local needle = query:lower()
	for _, user in ipairs(users) do
		local id = json.safe_str(user.account_id) or json.safe_str(user.uuid)
		local key = json.safe_str(user.uuid) or id
		local nickname = json.safe_str(user.nickname)
		local filter_text = user.display_name .. " " .. (nickname or "")
		if id and not seen[key] and filter_text:lower():find(needle, 1, true) then
			seen[key] = true
			items[#items + 1] = {
				label = "@" .. user.display_name,
				insert_text = "@{" .. id:gsub("[{}]", "") .. "}",
				filter_text = filter_text,
				detail = nickname,
			}
			if #items == 50 then
				break
			end
		end
	end
	return items
end

---@type AtlasCompletionSource
local users = {
	triggers = { "@" },

	complete = function(context, query, done)
		local repository = context.repository or (context.pr and context.pr.repo_full_name)
		if not repository then
			done({}, nil)
			return nil
		end

		local cache_key = "bitbucket:completion:users:" .. repository
		if context.pr then
			cache_key = cache_key .. "#" .. context.pr.id
		end
		local cached = service.get_cache(cache_key)
		if cached then
			done(completion_items(cached, query), nil)
			return nil
		end

		if not context.pr then
			local endpoint = string.format(
				"/repositories/%s/effective-default-reviewers?pagelen=100&fields=values.user.account_id,values.user.uuid,values.user.display_name,values.user.nickname,next",
				repository
			)
			return service.fetch_all_values(endpoint, function(result, err)
				if err or not result then
					done(nil, err)
					return
				end

				local candidates = vim.tbl_map(function(reviewer)
					return reviewer.user
				end, result.values)
				service.set_cache(cache_key, candidates)
				done(completion_items(candidates, query), nil)
			end, { action = "Fetch default reviewers", repo = repository })
		end

		local endpoint = string.format(
			"/repositories/%s/pullrequests/%s?fields=author,participants,reviewers",
			repository,
			context.pr.id
		)
		return service.request("GET", endpoint, nil, nil, function(result, err)
			if err or not result then
				done(nil, err)
				return
			end

			local candidates = { result.author }
			local reviewers = vim.list_extend({}, result.reviewers)
			for _, participant in ipairs(result.participants) do
				if participant.role == "REVIEWER" and not json.nilify(participant.participated_on) then
					reviewers[#reviewers + 1] = participant.user
				else
					candidates[#candidates + 1] = participant.user
				end
			end
			vim.list_extend(candidates, reviewers)
			service.set_cache(cache_key, candidates)
			done(completion_items(candidates, query), nil)
		end, { action = "Fetch PR mentionable users", repo = repository })
	end,
}

---@type AtlasCompletionSource
local pulls = {
	triggers = { "#" },

	complete = function(context, _, done)
		local repository = context.repository or (context.pr and context.pr.repo_full_name)
		if not repository or repository == "" then
			done(nil, "Bitbucket pull request completion requires a repository")
			return
		end

		local cache_key = "bitbucket:completion:pulls:" .. repository
		local cached = service.get_cache(cache_key)
		if cached then
			done(cached, nil)
			return
		end

		local endpoint = string.format(
			"/repositories/%s/pullrequests?pagelen=50&sort=-updated_on&state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED&fields=values.id,values.title,values.state,values.draft",
			repository
		)
		return service.request("GET", endpoint, nil, nil, function(result, err)
			if err or not result then
				done(nil, err or "Unable to fetch Bitbucket pull requests")
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local items = {}
			for _, item in ipairs(result.values) do
				local reference = "#" .. item.id
				local icon = item.draft and "draft_pr" or "pr"
				if item.state == "MERGED" then
					icon = "merged_pr"
				elseif item.state == "DECLINED" or item.state == "SUPERSEDED" then
					icon = "declined_pr"
				end
				items[#items + 1] = {
					label = icons.pulls(icon) .. " " .. reference,
					insert_text = "pull request " .. reference,
					filter_text = item.id .. " " .. item.title,
					detail = item.title,
				}
			end
			service.set_cache(cache_key, items)
			done(items, nil)
		end, { action = "Complete pull requests", repo = repository })
	end,
}

return {
	users = users,
	pulls = pulls,
}
