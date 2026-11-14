local service = require("atlas.providers.jira.client")

---@type AtlasCompletionSource
return {
	triggers = { "#" },

	complete = function(context, _, done)
		local project = context.project or (context.issue and context.issue.key:match("^([^-]+)-"))
		if not project or project == "" then
			done(nil, "Jira issue completion requires a project")
			return
		end

		local cache_key = "jira:completion:issues:" .. project
		local cached = service.get_cache(cache_key)
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
			local status_icons = require("atlas.config").options.issues.jira.project_config.status_icons
			local base_url = service.base_url()
			local items = {}
			for _, item in ipairs(result.issues) do
				local status = item.fields.status
				local icon = status_icons[status.name]
					or status_icons[status.statusCategory.key]
					or icons.get("fallback")
				items[#items + 1] = {
					label = icon .. " " .. item.key,
					insert_text = is_server and item.key
						or string.format("[%s](%s/browse/%s)", item.key, base_url, item.key),
					filter_text = item.key .. " " .. item.fields.summary,
					detail = item.fields.summary,
				}
			end
			service.set_cache(cache_key, items)
			done(items, nil)
		end, { action = "Complete issues", project = project })
	end,
}
