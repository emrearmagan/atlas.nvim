local service = require("atlas.providers.bitbucket.client")

---@type AtlasCompletionSource
return {
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
		return service.request("GET", endpoint, nil, function(result, err)
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
					label = icons.get(icon) .. " " .. reference,
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
