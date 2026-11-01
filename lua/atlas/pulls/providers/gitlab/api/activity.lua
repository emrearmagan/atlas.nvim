local M = {}

local service = require("atlas.providers.gitlab.client")
local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local request_scope = require("atlas.core.requests")
local mapper = require("atlas.pulls.providers.gitlab.api.mapper")

local function same_actor(left, right)
	return left.actor ~= nil and right.actor ~= nil and left.actor.username == right.actor.username
end

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_inline_thread_activity(entries)
	local squashed, current, count = {}, nil, 0

	local function flush()
		if not current then
			return
		end
		if count > 1 then
			current = {
				kind = "comment",
				actor = current.actor,
				date = current.date,
				label = string.format("started %d review threads", count),
				inline_thread = true,
			}
		end
		table.insert(squashed, current)
		current, count = nil, 0
	end

	for _, entry in ipairs(entries) do
		---@cast entry GitLabPullsActivityEntry
		if entry.inline_thread then
			if current and same_actor(current, entry) then
				count = count + 1
				current.date = entry.date or current.date
			else
				flush()
				current, count = entry, 1
			end
		else
			flush()
			table.insert(squashed, entry)
		end
	end
	flush()
	return squashed
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	opts = opts or {}
	local path = pr.repo_full_name
	local iid = tonumber(pr.id)
	if path == "" or iid == nil then
		vim.schedule(function()
			on_done(nil, "Invalid MR identifier")
		end)
		return nil
	end

	local cache_key = string.format("gitlab_pulls:activity:%s!%d", path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format(
		"/projects/%s/merge_requests/%d/notes?sort=asc&order_by=created_at",
		service.url_encode(path),
		iid
	)
	return service.fetch_all_pages(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, note in ipairs(result) do
			local e = mapper.to_activity(note)
			if e then
				table.insert(entries, e)
			end
		end
		entries = squash_inline_thread_activity(entries)
		service.set_memory_cache(cache_key, entries)
		on_done(entries, nil)
	end, {
		action = "Fetch MR activity",
		project_path = path,
		iid = iid,
	})
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(conversation: PullsConversation|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	local requests = request_scope.new()
	requests.all({
		activity = function(done)
			return M.fetch_activity(pr, opts, done)
		end,
		conversation = function(done)
			return comments_api.fetch_conversation_comments(pr, opts, done)
		end,
	}, function(values, errors)
		if values.activity == nil and values.conversation == nil then
			on_done(nil, errors.activity or errors.conversation or "Failed to fetch conversation")
			return
		end
		local conversation = values.conversation or { comments = {} }
		on_done({
			description = conversation.description,
			comments = conversation.comments,
			reviews = {},
			activities = values.activity or {},
		}, errors.activity or errors.conversation)
	end)
	return requests
end

return M
