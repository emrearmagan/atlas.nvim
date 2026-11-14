local client = require("atlas.providers.gitlab.client")
local issue_mapper = require("atlas.issues.providers.gitlab.api.mapper")
local json = require("atlas.core.json")

local ISSUES_QUERY = [[
query($path: ID!) {
  project(fullPath: $path) {
    issues(first: 100, sort: UPDATED_DESC) {
      nodes { iid title state }
    }
  }
}
]]

---@type AtlasCompletionSource
return {
	triggers = { "#" },

	complete = function(context, _, done)
		local project = context.repository
			or (context.pr and context.pr.repo_full_name)
			or (context.issue and issue_mapper.parse_key(context.issue.key))
		if not project or project == "" then
			done(nil, "GitLab issue completion requires a project")
			return
		end

		local key = "gitlab:completion:issues:" .. project
		local cached, found = client.get_cache(key)
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
				local icon = icons.get(item.state == "closed" and "success" or "issue")
				items[#items + 1] = {
					label = icon .. " " .. reference,
					insert_text = reference,
					filter_text = item.iid .. " " .. item.title,
					detail = item.title,
				}
			end
			client.set_cache(key, items)
			done(items, nil)
		end, { action = "Complete issues", project_path = project })
	end,
}
