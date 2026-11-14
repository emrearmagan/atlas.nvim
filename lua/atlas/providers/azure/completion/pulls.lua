local client = require("atlas.providers.azure.client")

---@type AtlasCompletionSource
return {
	triggers = { "!" },

	complete = function(context, _, done)
		local repository = context.repository or (context.pr and context.pr.repo_full_name)
		local project, repo = (repository or ""):match("^([^/]+)/(.+)$")
		project = project or context.project
		if not project then
			done(nil, "Azure pull request completion requires a project")
			return nil
		end

		local key = "completion:pulls:" .. (repository or project)
		local cached, found = client.get_cache(key)
		if found then
			done(cached, nil)
			return nil
		end

		local endpoint = "/"
			.. client.url_encode(project)
			.. "/_apis/git/"
			.. (repo and "repositories/" .. client.url_encode(repo) .. "/" or "")
			.. "pullrequests"
			.. client.build_query({ ["searchCriteria.status"] = "all", ["$top"] = 50 })

		return client.request("GET", endpoint, nil, function(result, err)
			if err then
				done(nil, err)
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local items = {}
			for _, item in ipairs(result.value) do
				local icon = item.isDraft and "draft_pr" or "pr"
				if item.status == "completed" then
					icon = "merged_pr"
				elseif item.status == "abandoned" then
					icon = "declined_pr"
				end

				local reference = "!" .. item.pullRequestId
				items[#items + 1] = {
					label = icons.get(icon) .. " " .. reference,
					insert_text = reference,
					filter_text = item.pullRequestId .. " " .. item.title,
					detail = item.title,
				}
			end

			client.set_cache(key, items)
			done(items, nil)
		end, { action = "Complete pull requests", project = project })
	end,
}
