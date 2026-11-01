local json = require("atlas.core.json")
local requests = require("atlas.core.requests")
local users = require("atlas.providers.forge.users")

local M = {}

---@param service ForgeService
---@return AtlasCompletionSource
function M.new(service)
	return {
		triggers = { "@" },
		complete = function(context, _, done)
			local repository = context.repository or (context.pr and context.pr.repo_full_name)
			local number = context.pr and context.pr.id
			if context.issue then
				local slug, issue_number = context.issue.key:match("^(.-)#(%d+)$")
				repository, number = repository or slug, issue_number
			end
			local owner, repo = tostring(repository or ""):match("^([^/]+)/([^/]+)$")
			if not owner then
				done(nil, service.name .. " user completion requires a repository")
				return nil
			end
			local key = table.concat({
				service.id,
				service.base_url(),
				"completion:users",
				repository,
				context.pr and "pull" or "issue",
				number or "",
			}, ":")
			local cached, found = service.get_memory_cache(key)
			if found then
				done(cached, nil)
				return nil
			end

			local function finish(candidates)
				local items, seen = {}, {}
				for _, user in ipairs(candidates) do
					if user.username and not seen[user.username] then
						seen[user.username] = true
						items[#items + 1] = {
							label = "@" .. user.username,
							insert_text = "@" .. user.username,
							filter_text = user.username .. " " .. user.name,
							detail = user.name,
						}
					end
				end
				service.set_memory_cache(key, items)
				done(items, nil)
			end

			if not number then
				return service.users.get_assignable_users(repository, nil, function(candidates, err)
					if err then
						done(nil, err)
						return
					end
					finish(candidates)
				end)
			end

			local base = string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
			local issue = base .. "/issues/" .. number
			local starts = {
				item = function(callback)
					local endpoint = context.pr and base .. "/pulls/" .. number or issue
					return service.request("GET", endpoint, nil, callback)
				end,
				comments = function(callback)
					return service.fetch_all(issue .. "/comments", nil, nil, callback)
				end,
			}
			if context.pr then
				starts.reviews = function(callback)
					return service.fetch_all(base .. "/pulls/" .. number .. "/reviews", nil, nil, callback)
				end
			end
			local scope = requests.new()
			scope.all(starts, function(values, errors)
				local err = errors.item or errors.comments or errors.reviews
				if err then
					done(nil, err)
					return
				end
				local candidates = {}
				local function add(raw)
					local user = users.to_user(raw)
					if user then
						candidates[#candidates + 1] = user
					end
				end
				add(values.item.user)
				for _, assignee in ipairs(json.safe_table(values.item.assignees)) do
					add(assignee)
				end
				for _, reviewer in ipairs(json.safe_table(values.item.requested_reviewers)) do
					add(reviewer)
				end
				for _, comment in ipairs(values.comments) do
					add(comment.user)
				end
				for _, review in ipairs(values.reviews or {}) do
					add(review.user)
				end
				finish(candidates)
			end)
			return scope
		end,
	}
end

return M
