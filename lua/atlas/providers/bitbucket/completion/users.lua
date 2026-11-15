local service = require("atlas.providers.bitbucket.client")
local json = require("atlas.core.json")

---@param user AtlasUser
---@return string|nil
local function format_mention(user)
	if user.id and user.id ~= "" then
		return "@{" .. user.id:gsub("[{}]", "") .. "}"
	end
end

---@param users table[]
---@param query string
---@return AtlasCompletionItem[]
local function completion_items(users, query)
	local items, seen = {}, {}
	local needle = query:lower()
	for _, user in ipairs(users) do
		local id = json.safe_str(user.account_id) or json.safe_str(user.uuid)
		local mention = format_mention({ id = id, name = user.display_name })
		local key = json.safe_str(user.uuid) or id
		local nickname = json.safe_str(user.nickname)
		local filter_text = user.display_name .. " " .. (nickname or "")
		if key and mention and not seen[key] and filter_text:lower():find(needle, 1, true) then
			seen[key] = true
			items[#items + 1] = {
				label = "@" .. user.display_name,
				insert_text = mention,
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
return {
	triggers = { "@" },
	format_mention = format_mention,

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
		return service.request("GET", endpoint, nil, function(result, err)
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
