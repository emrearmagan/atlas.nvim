local service = require("atlas.providers.jira.client")
local mapper = require("atlas.providers.jira.mapper")
local url_encode = require("atlas.core.utils").url_encode

---@param user AtlasUser
---@return string|nil
local function format_mention(user)
	if user.id and user.id ~= "" then
		return service.is_server() and "[~" .. user.id .. "]"
			or string.format("[@%s](atlas-mention:%s)", user.name, user.id)
	end
end

---@type AtlasCompletionSource
return {
	triggers = { "@" },
	format_mention = format_mention,

	complete = function(context, query, done)
		local issue_key = context.issue and context.issue.key
		local scope = issue_key or context.project
		if not scope or scope == "" then
			done({}, nil)
			return nil
		end

		local is_server = service.is_server()
		local endpoint = string.format(
			"/user/viewissue/search?%s=%s&%s=%s&maxResults=1000",
			is_server and "username" or "query",
			url_encode(query),
			issue_key and "issueKey" or "projectKey",
			url_encode(scope)
		)
		local cache_key = "jira:completion:users:" .. scope .. ":" .. query
		local cached = service.get_memory_cache(cache_key)
		if cached then
			done(cached, nil)
			return nil
		end

		return service.request("GET", endpoint, nil, function(result, err)
			if err or not result then
				done(nil, err)
				return
			end

			---@type AtlasCompletionItem[]
			local items = {}
			for _, raw_user in ipairs(result) do
				local user = mapper.to_user(raw_user)
				local mention = user and format_mention(user)
				if user and mention and raw_user.active ~= false then
					table.insert(items, {
						label = "@" .. user.name,
						insert_text = mention,
						filter_text = user.name .. " " .. (user.username or ""),
						detail = user.username,
					})
					if #items == 50 then
						break
					end
				end
			end

			service.set_memory_cache(cache_key, items)
			done(items, nil)
		end, { action = "Fetch mentionable users", issue_key = issue_key, project = context.project })
	end,
}
