local service = require("atlas.providers.gitea.client").pulls
local pagination = require("atlas.providers.gitea.pagination").pulls
local mapper = require("atlas.pulls.providers.gitea.api.mapper")
local reviews = require("atlas.pulls.providers.gitea.api.reviews")
local pullrequests = require("atlas.pulls.providers.gitea.api.pullrequests")
local request_scope = require("atlas.core.requests")

local M = {}

---@param value table
---@return string|nil
local function review_id(value)
	local id = value.review_id
	return id and id > 0 and tostring(id) or nil
end

---@param left PullsActivityEntry
---@param right PullsActivityEntry
---@return boolean
local function same_actor(left, right)
	local left_user = left.actor
	local right_user = right.actor
	if not left_user or not right_user then
		return false
	end
	return left_user.id == right_user.id
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
			if current and same_actor(current, entry) then
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
---@param comment PullsComment
---@return string|nil
local function reactions_endpoint(base, pr, comment)
	local id = tostring(comment.id)
	if id == "__body__" then
		return string.format("%s/issues/%s/reactions", base, pr.id)
	elseif id:match("^%d+$") then
		return string.format("%s/issues/comments/%s/reactions", base, id)
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

	return pagination.fetch_all(string.format("%s/pulls/%s/reviews", base, pr.id), nil, {
		post_filtered = true,
	}, function(raw_reviews, err)
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

function M.fetch(pr, opts, on_done)
	opts = opts or {}
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return pagination.fetch_all(string.format("%s/issues/%s/timeline", base, pr.id), nil, {
			post_filtered = true,
		}, done)
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
			local activity_only = opts.activity_only == true
			local description = tostring(pr.description or "")
			if not activity_only and description ~= "" then
				table.insert(comments, {
					id = "__body__",
					parent_id = nil,
					author = pr.author,
					content_raw = description,
					created_on = pr.created_on,
					reactions = pr.reactions,
				})
			end
			for _, value in ipairs(enriched.timeline) do
				local event = tostring(value.type or ""):lower()
				if event == "comment" then
					if not activity_only then
						table.insert(comments, mapper.to_comment(value))
					end
				else
					local id = review_id(value)
					local activity = mapper.to_activity(value, id and enriched.reviews[id] or nil)
					if activity then
						table.insert(events, activity)
					end
				end
			end
			events = squash_pushes(events)
			if activity_only then
				on_done({ comments = {}, events = events }, nil)
				return
			end
			-- TODO: Figure out how the fuck to load reactions without N+1 requests.
			on_done({ comments = comments, events = events }, nil)
		end)
	end)
	return requests
end

function M.fetch_activity(pr, _, on_done)
	return M.fetch(pr, { activity_only = true }, function(result, err)
		on_done(result and result.events or nil, err)
	end)
end

function M.add(pr, content, opts, on_done)
	local base = endpoint(pr)
	if not base or vim.trim(content) == "" then
		on_done(nil, not base and "Invalid Gitea repository" or "Comment cannot be empty")
		return nil
	end
	local parent = opts and opts.parent or nil
	if parent and parent.inline then
		local root_id = tostring(parent.parent_id or parent.id)
		if not root_id:match("^%d+$") then
			on_done(nil, "Invalid Gitea review comment")
			return nil
		end
		return service.request(
			"POST",
			string.format("%s/pulls/%s/comments/%s/replies", base, pr.id, root_id),
			{ body = content },
			function(raw, err)
				if err then
					on_done(nil, err)
					return
				end
				local created = mapper.to_comment(raw)
				created.parent_id = parent.parent_id or parent.id
				created.inline = created.inline or parent.inline
				created.inline_hunk = created.inline_hunk or parent.inline_hunk
				created.outdated = parent.outdated
				on_done(created, nil)
			end
		)
	end
	if opts and opts.file then
		on_done(nil, "Gitea does not support file-level review comments")
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

---@param pr PullRequest
---@param root PullsComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	local base = endpoint(pr)
	local root_id = tostring(root.parent_id or root.id)
	if not base or not root_id:match("^%d+$") or not root.inline then
		on_done(false, "Invalid Gitea review thread")
		return nil
	end
	local action = resolved and "resolve" or "unresolve"
	return service.request(
		"POST",
		string.format("%s/pulls/comments/%s/%s", base, root_id, action),
		nil,
		function(_, err)
			on_done(err == nil, err)
		end
	)
end

function M.edit(pr, comment, on_done)
	local base = endpoint(pr)
	local id = tostring(comment.id)
	if id == "__body__" then
		return pullrequests.update_description(pr, comment.content_raw, function(ok, err)
			on_done(ok and comment or nil, err)
		end)
	end
	if not base or not id:match("^%d+$") then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end
	return service.request("PATCH", string.format("%s/issues/comments/%s", base, id), {
		body = comment.content_raw,
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local updated = mapper.to_comment(raw)
		on_done(vim.tbl_extend("force", {}, comment, updated), nil)
	end)
end

function M.delete(pr, comment, on_done)
	local base = endpoint(pr)
	local id = tostring(comment.id)
	if id == "__body__" then
		on_done(false, "Cannot delete the pull request description")
		return nil
	end
	if not base or not id:match("^%d+$") then
		on_done(false, "Invalid Gitea repository")
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
		on_done(false, "Invalid Gitea repository")
		return nil
	end
	local target = reactions_endpoint(base, pr, comment)
	if not target then
		on_done(false, "Invalid Gitea comment")
		return nil
	end
	return service.request("POST", target, { content = key }, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
