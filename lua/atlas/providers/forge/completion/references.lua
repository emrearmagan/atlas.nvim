local json = require("atlas.core.json")

local M = {}

---@param raw table Issue or pull request from the repository issue list.
---@return string
local function icon_name(raw)
	local pull = json.nilify(raw.pull_request)
	if not pull then
		return raw.state == "closed" and "success" or "issue"
	end
	if pull.merged == true then
		return "merged_pr"
	end
	if raw.state == "closed" then
		return "declined_pr"
	end
	return pull.draft == true and "draft_pr" or "pr"
end

---@param service ForgeService
---@return AtlasCompletionSource
function M.new(service)
	return {
		triggers = { "#" },
		complete = function(context, _, done)
			local repository = context.repository or (context.pr and context.pr.repo_full_name)
			if not repository and context.issue then
				repository = context.issue.key:match("^(.-)#%d+$")
			end
			local owner, repo = tostring(repository or ""):match("^([^/]+)/([^/]+)$")
			if not owner then
				done(nil, service.name .. " reference completion requires a repository")
				return nil
			end

			local key = table.concat({ service.id, service.base_url(), "completion:references", repository }, ":")
			local cached, found = service.get_memory_cache(key)
			if found then
				done(cached, nil)
				return nil
			end

			local endpoint = string.format("/repos/%s/%s/issues", service.url_encode(owner), service.url_encode(repo))
				.. service.query({ state = "all", limit = 50 })
			return service.request("GET", endpoint, nil, function(raw, err)
				if err then
					done(nil, err)
					return
				end

				local icons = require("atlas.ui.shared.icons")
				local items = {}
				for _, value in ipairs(json.safe_table(raw)) do
					local reference = "#" .. value.number
					items[#items + 1] = {
						label = icons.get(icon_name(value)) .. " " .. reference,
						insert_text = reference,
						filter_text = value.number .. " " .. tostring(value.title or ""),
						detail = value.title,
					}
				end
				service.set_memory_cache(key, items)
				done(items, nil)
			end, { action = "Complete references", repo = repository })
		end,
	}
end

return M
