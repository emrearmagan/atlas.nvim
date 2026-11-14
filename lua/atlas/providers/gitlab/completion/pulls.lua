local client = require("atlas.providers.gitlab.client")
local issue_mapper = require("atlas.issues.providers.gitlab.api.mapper")
local json = require("atlas.core.json")

local PULLS_QUERY = [[
query($path: ID!) {
  project(fullPath: $path) {
    mergeRequests(first: 100, sort: UPDATED_DESC) {
      nodes { iid title state draft }
    }
  }
}
]]

---@type AtlasCompletionSource
return {
	triggers = { "!" },

	complete = function(context, _, done)
		local project = context.repository
			or (context.pr and context.pr.repo_full_name)
			or (context.issue and issue_mapper.parse_key(context.issue.key))
		if not project or project == "" then
			done(nil, "GitLab merge request completion requires a project")
			return
		end

		local key = "gitlab:completion:pulls:" .. project
		local cached, found = client.get_cache(key)
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
					label = icons.get(icon) .. " " .. reference,
					insert_text = reference,
					filter_text = item.iid .. " " .. item.title,
					detail = item.title,
				}
			end
			client.set_cache(key, items)
			done(items, nil)
		end, { action = "Complete merge requests", project_path = project })
	end,
}
