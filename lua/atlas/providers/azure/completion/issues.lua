local client = require("atlas.providers.azure.client")
local issues = require("atlas.issues.providers.azure.api.issues")
local requests = require("atlas.core.requests")

---@type AtlasCompletionSource
return {
	triggers = { "#" },

	complete = function(context, _, done)
		local repository = context.repository or (context.pr and context.pr.repo_full_name)
		local project = context.project or (repository and repository:match("^([^/]+)/"))

		local key = "completion:workitems:" .. (project or "")
		local cached, found = client.get_cache(key)
		if found then
			done(cached, nil)
			return nil
		end

		local endpoint = (project and "/" .. client.url_encode(project) or "")
			.. "/_apis/wit/wiql"
			.. client.build_query({ ["$top"] = 50 })
		local query = "SELECT [System.Id] FROM WorkItems"
			.. (project and " WHERE [System.TeamProject] = @project" or "")
			.. " ORDER BY [System.ChangedDate] DESC"

		local scope = requests.new()
		scope.run(function(callback)
			return client.request("POST", endpoint, { query = query }, callback, {
				action = "Complete work items",
				project = project,
			})
		end, function(result, err)
			if err then
				done(nil, err)
				return
			end

			local refs = {}
			for _, item in ipairs(result.workItems) do
				table.insert(refs, { key = tostring(item.id) })
			end

			scope.run(function(callback)
				return issues.fetch_by_refs(refs, {}, callback)
			end, function(items, items_err)
				if items_err then
					done(nil, items_err)
					return
				end

				local icons = require("atlas.ui.shared.icons")
				local completions = {}
				for _, item in ipairs(items) do
					local reference = "#" .. item.key
					completions[#completions + 1] = {
						label = icons.get("issue") .. " " .. reference,
						insert_text = reference,
						filter_text = item.key .. " " .. item.title,
						detail = item.title,
					}
				end

				client.set_cache(key, completions)
				done(completions, nil)
			end)
		end)
		return scope
	end,
}
