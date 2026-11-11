local client = require("atlas.providers.azure.client")
local comments = require("atlas.issues.providers.azure.api.comments")
local issues = require("atlas.issues.providers.azure.api.issues")
local users_api = require("atlas.providers.azure.users")
local requests = require("atlas.core.requests")

---@param user AtlasUser
---@return string|nil
local function format_mention(user)
	if user.id and user.id ~= "" then
		return "@<" .. user.id .. ">"
	end
end

---@param authors table<string, string>
---@param query string
---@return AtlasCompletionItem[]
local function completion_items(authors, query)
	local items = {}
	for id, name in pairs(authors) do
		local mention = format_mention({ id = id, name = name })
		if mention and name:lower():find(query:lower(), 1, true) then
			items[#items + 1] = {
				label = "@" .. name,
				insert_text = mention,
				filter_text = name,
			}
		end
	end
	table.sort(items, function(a, b)
		return a.label < b.label
	end)
	return items
end

---@type AtlasCompletionSource
return {
	triggers = { "@" },
	format_mention = format_mention,
	complete = function(context, query, done)
		local pr = context.pr
		local issue = context.issue
		local key
		if issue then
			key = "completion:users:issue:" .. issue.key
		elseif pr then
			key = "completion:users:pr:" .. pr.repo_full_name .. ":" .. pr.id
		else
			done({}, nil)
			return nil
		end
		local cached, found = client.get_cache(key)
		if found then
			done(completion_items(cached, query), nil)
			return nil
		end
		local scope = requests.new()
		local function finish(authors)
			client.set_cache(key, authors)
			done(completion_items(authors, query), nil)
		end
		if issue then
			scope.run(function(callback)
				return issues.fetch_by_refs({ issue }, {}, callback)
			end, function(items, err)
				if err or not items or not items[1] then
					done(nil, err or "Work item not found")
					return
				end
				local item = items[1]
				scope.run(function(callback)
					return comments.fetch_conversation(item, {}, callback)
				end, function(conversation, comment_err)
					if comment_err then
						done(nil, comment_err)
						return
					end
					local authors = {}
					users_api.add_mention_name(authors, item.reporter)
					users_api.add_mention_name(authors, item.assignee)
					for _, comment in ipairs(conversation and conversation.comments or {}) do
						users_api.add_mention_name(authors, comment.author)
					end
					finish(authors)
				end)
			end)
		elseif pr then
			local project, repository = pr.repo_full_name:match("^([^/]+)/(.+)$")
			if not project then
				done(nil, "Azure pull request completion requires a project and repository")
				return nil
			end
			local endpoint = string.format(
				"/%s/_apis/git/repositories/%s/pullrequests/%s",
				client.url_encode(project),
				client.url_encode(repository),
				pr.id
			)
			scope.all({
				pull = function(callback)
					return client.request("GET", endpoint, nil, callback, { action = "Fetch PR mentionable users" })
				end,
				threads = function(callback)
					return client.request(
						"GET",
						endpoint .. "/threads",
						nil,
						callback,
						{ action = "Fetch PR mentionable users" }
					)
				end,
			}, function(values, errors)
				local err = errors.pull or errors.threads
				if err then
					done(nil, err)
					return
				end
				local authors = {}
				users_api.add_mention_name(authors, users_api.to_user(values.pull.createdBy))
				for _, reviewer in ipairs(values.pull.reviewers or {}) do
					users_api.add_mention_name(authors, users_api.to_user(reviewer))
				end
				for _, thread in ipairs(values.threads.value or {}) do
					for _, comment in ipairs(thread.comments or {}) do
						users_api.add_mention_name(authors, users_api.to_user(comment.author))
					end
				end
				finish(authors)
			end)
		end
		return scope
	end,
}
