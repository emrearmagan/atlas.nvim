local service = require("atlas.providers.jira.client")
local users_api = require("atlas.providers.jira.users")
local url_encode = require("atlas.core.utils").url_encode

---@type AtlasCompletionSource
local users = {
	triggers = { "@" },

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
				local user = users_api.to_user(raw_user)
				if user and user.id and user.id ~= "" and raw_user.active ~= false then
					table.insert(items, {
						label = "@" .. user.name,
						insert_text = is_server and "[~" .. user.id .. "]"
							or string.format("[@%s](atlas-mention:%s)", user.name, user.id),
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

---@type AtlasCompletionSource
local issues = {
	triggers = { "#" },

	complete = function(context, _, done)
		local project = context.project or (context.issue and context.issue.key:match("^([^-]+)-"))
		if not project or project == "" then
			done(nil, "Jira issue completion requires a project")
			return
		end

		local cache_key = "jira:completion:issues:" .. project
		local cached = service.get_memory_cache(cache_key)
		if cached then
			done(cached, nil)
			return
		end

		local is_server = service.is_server()
		local endpoint = is_server and "/search" or "/search/jql"
		local data = {
			jql = string.format('project = "%s" ORDER BY updated DESC', project),
			fields = { "summary", "status" },
			maxResults = 100,
		}
		return service.request("POST", endpoint, data, function(result, err)
			if err or not result then
				done(nil, err or "Unable to fetch Jira issues")
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local base_url = service.base_url():gsub("/+$", "")
			local items = {}
			for _, item in ipairs(result.issues) do
				local status = item.fields.status
				local icon = icons.issues_status(status.statusCategory.key, status.name)
				items[#items + 1] = {
					label = icon .. " " .. item.key,
					insert_text = is_server and item.key
						or string.format("[%s](%s/browse/%s)", item.key, base_url, item.key),
					filter_text = item.key .. " " .. item.fields.summary,
					detail = item.fields.summary,
				}
			end
			service.set_memory_cache(cache_key, items)
			done(items, nil)
		end, { action = "Complete issues", project = project })
	end,
}

return {
	users = users,
	issues = issues,
}
