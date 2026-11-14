local client = require("atlas.providers.github.client")
local issue_mapper = require("atlas.issues.providers.github.api.mapper")

local PULLS_QUERY = [[
query($search: String!) {
  search(query: $search, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest { number title state isDraft }
    }
  }
}
]]

---@type AtlasCompletionSource
return {
	triggers = { "#" },

	complete = function(context, _, done)
		local repository = context.repository
			or (context.pr and context.pr.repo_full_name)
			or (context.issue and issue_mapper.parse_key(context.issue.key))
		if not repository or repository == "" then
			done(nil, "GitHub pull request completion requires a repository")
			return
		end

		local key = "github:completion:pulls:" .. repository
		local cached, found = client.get_cache(key)
		if found then
			done(cached, nil)
			return
		end

		local args = {
			"api",
			"graphql",
			"-f",
			"query=" .. PULLS_QUERY,
			"-f",
			"search=repo:" .. repository .. " is:pr sort:updated-desc",
		}
		return client.gh(args, function(result, err)
			if err or not result then
				done(nil, err or "Unable to fetch GitHub pull requests")
				return
			end

			local icons = require("atlas.ui.shared.icons")
			local items = {}
			for _, item in ipairs(result.data.search.nodes) do
				local reference = "#" .. item.number
				local icon = item.isDraft and "draft_pr" or "pr"
				if item.state == "MERGED" then
					icon = "merged_pr"
				elseif item.state == "CLOSED" then
					icon = "declined_pr"
				end
				items[#items + 1] = {
					label = icons.get(icon) .. " " .. reference,
					insert_text = reference,
					filter_text = item.number .. " " .. item.title,
					detail = item.title,
				}
			end
			client.set_cache(key, items)
			done(items, nil)
		end, { action = "Complete pull requests", repo = repository })
	end,
}
