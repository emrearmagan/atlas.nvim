local api = require("atlas.pulls.providers.forge.forgejo.api")
local service = require("atlas.providers.forge.forgejo.api")
local mapper = api.mapper
local reviews = require("atlas.pulls.providers.forge.forgejo.api.reviews")
local request_scope = require("atlas.core.requests")

local M = {}

---@param value table
---@return string|nil
local function review_id(value)
	local id = value.review_id
	return id and id > 0 and tostring(id) or nil
end

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_pushes(entries)
	local result, current, count, commit_ids = {}, nil, 0, {}
	local function add(entry)
		for _, id in ipairs(entry._commit_ids) do
			id = tostring(id)
			if id ~= "" and not commit_ids[id] then
				commit_ids[id] = true
				count = count + 1
			end
		end
	end
	local function flush()
		if not current then
			return
		end
		current.label = string.format("pushed %d commit%s", count, count == 1 and "" or "s")
		current._commit_ids = nil
		table.insert(result, current)
		current, count, commit_ids = nil, 0, {}
	end
	for _, entry in ipairs(entries) do
		local entry_count = entry.kind == "update"
				and tonumber(tostring(entry.label or ""):match("^pushed (%d+) commit"))
			or nil
		if entry_count then
			if current and current.actor and entry.actor and current.actor.id == entry.actor.id then
				add(entry)
				current.date = entry.date
			else
				flush()
				current = entry
				add(entry)
			end
		else
			flush()
			table.insert(result, entry)
		end
	end
	flush()
	return result
end

---@param pr PullRequest
---@return string|nil
local function endpoint(pr)
	if not tostring(pr.id):match("^%d+$") then
		return nil
	end
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

---@param base string
---@param pr PullRequest
---@param timeline table[]
---@param on_done fun(result: { timeline: table[], reviews: table<string, table> }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function enrich_review_events(base, pr, timeline, on_done)
	local has_reviews = false
	for _, value in ipairs(timeline) do
		if tostring(value.type or ""):lower() == "review" then
			has_reviews = true
			break
		end
	end
	if not has_reviews then
		on_done({ timeline = timeline, reviews = {} }, nil)
		return nil
	end

	return service.fetch_all(string.format("%s/pulls/%s/reviews", base, pr.id), nil, nil, function(raw_reviews, err)
		if err then
			on_done(nil, err)
			return
		end
		local by_id = {}
		for _, review in ipairs(raw_reviews) do
			if review.id ~= nil then
				by_id[tostring(review.id)] = review
			end
		end
		local last_review_event = {}
		for index, value in ipairs(timeline) do
			if tostring(value.type or ""):lower() == "review" then
				local id = review_id(value)
				if id then
					last_review_event[id] = index
				end
			end
		end

		local result = {}
		for index, value in ipairs(timeline) do
			local id = review_id(value)
			if id == nil or last_review_event[id] == index then
				table.insert(result, value)
			end
		end
		on_done({ timeline = result, reviews = by_id }, nil)
	end)
end

function M.fetch(pr, _opts, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.fetch_all(string.format("%s/issues/%s/timeline", base, pr.id), nil, nil, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return enrich_review_events(base, pr, raw, done)
		end, function(enriched, review_err)
			if review_err then
				on_done(nil, review_err)
				return
			end
			local comments, events = {}, {}
			for _, value in ipairs(enriched.timeline) do
				local event = tostring(value.type or ""):lower()
				if event == "comment" then
					table.insert(comments, mapper.to_comment(value))
				else
					local id = review_id(value)
					local activity = mapper.to_activity(value, id and enriched.reviews[id] or nil)
					if activity then
						table.insert(events, activity)
					end
				end
			end
			events = squash_pushes(events)
			-- TODO: Figure out how the fuck to load reactions without N+1 requests.
			on_done({ comments = comments, events = events }, nil)
		end)
	end)
	return requests
end

function M.add(pr, content, opts, on_done)
	local base = endpoint(pr)
	if not base or vim.trim(content) == "" then
		on_done(nil, not base and "Invalid Forgejo repository" or "Comment cannot be empty")
		return nil
	end
	local parent = opts and opts.parent or nil
	if parent and parent.inline then
		on_done(nil, "Forgejo does not support replies to review comments through its API")
		return nil
	end
	if opts and opts.file then
		on_done(nil, "Forgejo does not support file-level review comments")
		return nil
	end
	if opts and opts.inline then
		return reviews.add(pr, content, opts.inline, opts, on_done)
	end
	return service.request(
		"POST",
		string.format("%s/issues/%s/comments", base, pr.id),
		{ body = content },
		function(raw, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(mapper.to_comment(raw), nil)
		end
	)
end

function M.edit(pr, comment, on_done)
	local base = endpoint(pr)
	local id = tostring(comment.id)
	if not base or not id:match("^%d+$") then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", string.format("%s/issues/comments/%s", base, id), {
		body = comment.content_raw,
	}, function(_, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(comment, nil)
	end)
end

function M.delete(pr, comment, on_done)
	local base = endpoint(pr)
	local id = tostring(comment.id)
	if not base or not id:match("^%d+$") then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	if comment.inline then
		return reviews.delete(pr, comment, on_done)
	end
	return service.request("DELETE", string.format("%s/issues/comments/%s", base, id), nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
function M.add_reaction(pr, comment, key, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	local id = tostring(comment.id)
	if not id:match("^%d+$") then
		on_done(false, "Invalid Forgejo comment")
		return nil
	end
	local target = string.format("%s/issues/comments/%s/reactions", base, id)
	return service.request("POST", target, { content = key }, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
