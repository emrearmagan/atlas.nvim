local service = require("atlas.providers.gitea.forgejo.client").pulls
local pagination = require("atlas.pulls.providers.gitea.forgejo.api.pagination")
local mapper = require("atlas.pulls.providers.gitea.forgejo.api.mapper")
local reviews = require("atlas.pulls.providers.gitea.forgejo.api.reviews")
local pullrequests = require("atlas.pulls.providers.gitea.forgejo.api.pullrequests")
local request_scope = require("atlas.core.requests")

local M = {}

local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if key ~= "__http_status" and type(key) ~= "number" then
			return false
		end
	end
	return true
end

---@param value table
---@return string|nil
local function review_id(value)
	local id = value.review_id
	return id and id > 0 and tostring(id) or nil
end

local function same_actor(left, right)
	local left_user = type(left) == "table" and left.actor or nil
	local right_user = type(right) == "table" and right.actor or nil
	if type(left_user) ~= "table" or type(right_user) ~= "table" then
		return false
	end
	local left_id = tostring(left_user.id or left_user.username or "")
	local right_id = tostring(right_user.id or right_user.username or "")
	return left_id ~= "" and left_id == right_id
end

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_pushes(entries)
	local result, current, count, commit_ids = {}, nil, 0, {}
	local function add(entry, fallback)
		local ids = type(entry._commit_ids) == "table" and entry._commit_ids or {}
		if #ids == 0 then
			count = count + fallback
			return
		end
		for _, id in ipairs(ids) do
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
				add(entry, entry_count)
				current.date = entry.date or current.date
			else
				flush()
				current = entry
				add(entry, entry_count)
			end
		else
			flush()
			table.insert(result, entry)
		end
	end
	flush()
	return result
end

local function endpoint(pr)
	if type(pr) ~= "table" or not tostring(pr.id or ""):match("^%d+$") then
		return nil
	end
	local owner, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	if owner then
		return string.format("/repos/%s/%s", service.url_encode(owner), service.url_encode(repo))
	end
end

---@param base string
---@param pr PullRequest
---@param comment PullsComment
---@return string|nil
local function reactions_endpoint(base, pr, comment)
	local id = type(comment) == "table" and tostring(comment.id or "") or ""
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
		if type(value) == "table" and tostring(value.type or ""):lower() == "review" then
			has_reviews = true
			break
		end
	end
	if not has_reviews then
		on_done({ timeline = timeline, reviews = {} }, nil)
		return nil
	end

	return pagination.fetch_all(string.format("%s/pulls/%s/reviews", base, pr.id), nil, {
		invalid_response = "Invalid pull request reviews response",
		post_filtered = true,
	}, function(raw_reviews, err)
		if err then
			on_done(nil, err)
			return
		end
		local by_id = {}
		for _, review in ipairs(raw_reviews or {}) do
			if type(review) == "table" and review.id ~= nil then
				by_id[tostring(review.id)] = review
			end
		end
		local last_review_event = {}
		for index, value in ipairs(timeline) do
			if type(value) == "table" and tostring(value.type or ""):lower() == "review" then
				local id = review_id(value)
				if id then
					last_review_event[id] = index
				end
			end
		end

		local result = {}
		for index, value in ipairs(timeline) do
			local id = type(value) == "table" and review_id(value) or nil
			if id == nil or last_review_event[id] == index then
				table.insert(result, value)
			end
		end
		on_done({ timeline = result, reviews = by_id }, nil)
	end)
end

function M.fetch(pr, opts, on_done)
	local base = endpoint(pr)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return pagination.fetch_all(string.format("%s/issues/%s/timeline", base, pr.id), nil, {
			invalid_response = "Invalid pull request timeline response",
			post_filtered = true,
		}, done)
	end, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return enrich_review_events(base, pr, raw or {}, done)
		end, function(enriched, review_err)
			if review_err or not enriched then
				on_done(nil, review_err or "Invalid pull request reviews response")
				return
			end
			local comments, events = {}, {}
			local activity_only = type(opts) == "table" and opts.activity_only == true
			local description = tostring(pr.description or "")
			if not activity_only and description ~= "" then
				table.insert(comments, {
					id = "__body__",
					parent_id = nil,
					author = pr.author,
					content_raw = description,
					created_on = tostring(pr.created_on or ""),
					reactions = pr.reactions,
				})
			end
			for _, value in ipairs(enriched.timeline) do
				local event = type(value) == "table" and tostring(value.type or ""):lower() or ""
				if event == "comment" then
					if not activity_only then
						local comment = mapper.to_comment(value)
						if not comment then
							on_done(nil, "Invalid pull request comments response")
							return
						end
						table.insert(comments, comment)
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
			local starts = {}
			for index, comment in ipairs(comments) do
				local target = reactions_endpoint(base, pr, comment)
				if target then
					starts[tostring(index)] = function(done)
						local function mapped(values, reactions_err)
							if reactions_err then
								done(nil, reactions_err)
								return
							end
							done(mapper.reaction_counts(values), nil)
						end
						if comment.id == "__body__" then
							return pagination.fetch_all(target, nil, {
								invalid_response = "Invalid Forgejo reactions response",
							}, mapped)
						end
						return service.request("GET", target, nil, function(values, reactions_err)
							if not reactions_err and not is_list(values) then
								reactions_err = "Invalid Forgejo reactions response"
							end
							mapped(values, reactions_err)
						end)
					end
				end
			end
			requests.all(starts, function(values)
				for index, reactions in pairs(values) do
					local comment = comments[tonumber(index)]
					if comment then
						comment.reactions = reactions
						if comment.id == "__body__" then
							pr.reactions = reactions
						end
					end
				end
				on_done({ comments = comments, events = events }, nil)
			end)
		end)
	end)
	return requests
end

function M.fetch_activity(pr, _, on_done)
	return M.fetch(pr, { activity_only = true }, function(result, err)
		on_done(type(result) == "table" and result.events or nil, err)
	end)
end

function M.add(pr, content, opts, on_done)
	local base = endpoint(pr)
	if not base or vim.trim(content) == "" then
		on_done(nil, not base and "Invalid Forgejo repository" or "Comment cannot be empty")
		return nil
	end
	local parent = opts and opts.parent or nil
	if parent and parent.inline then
		local raw = type(parent._raw) == "table" and parent._raw or {}
		local review_id = tostring(raw.review_id or "")
		local inline = parent.inline
		local path = tostring(inline.path or "")
		local new_line = tonumber(inline.start_to or inline.to)
		local old_line = tonumber(inline.start_from or inline.from)
		if not review_id:match("^%d+$") or path == "" or (not new_line and not old_line) then
			on_done(nil, "Invalid Forgejo review comment")
			return nil
		end
		local payload = { body = content, path = path }
		if new_line then
			payload.new_position = new_line
			local finish = tonumber(inline.to)
			if finish and finish > new_line then
				payload.extra_lines_count = finish - new_line
			end
		else
			payload.old_position = old_line
			local finish = tonumber(inline.from)
			if finish and finish > old_line then
				payload.extra_lines_count = finish - old_line
			end
		end
		return service.request(
			"POST",
			string.format("%s/pulls/%s/reviews/%s/comments", base, pr.id, review_id),
			payload,
			function(value, err)
				local created = not err and mapper.to_comment(value, { id = review_id }) or nil
				if not created then
					on_done(nil, err or "Invalid review comment response")
					return
				end
				created.parent_id = parent.parent_id or parent.id
				created.inline = created.inline or parent.inline
				created.inline_hunk = created.inline_hunk or parent.inline_hunk
				created.outdated = parent.outdated
				on_done(created, nil)
			end
		)
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
			local comment = mapper.to_comment(raw)
			if comment == nil then
				on_done(nil, "Invalid comment response")
				return
			end
			on_done(comment, nil)
		end
	)
end

function M.edit(pr, comment, on_done)
	local base = endpoint(pr)
	local id = type(comment) == "table" and tostring(comment.id or "") or ""
	if id == "__body__" then
		return pullrequests.update_description(pr, tostring(comment.content_raw or ""), function(ok, err)
			on_done(ok and comment or nil, err)
		end)
	end
	if not base or not id:match("^%d+$") then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end
	return service.request("PATCH", string.format("%s/issues/comments/%s", base, id), {
		body = tostring(comment.content_raw or ""),
	}, function(raw, err)
		if err then
			on_done(nil, err)
			return
		end
		local updated = mapper.to_comment(raw)
		if updated == nil then
			on_done(nil, "Invalid comment response")
			return
		end
		on_done(vim.tbl_extend("force", {}, comment, updated), nil)
	end)
end

function M.delete(pr, comment, on_done)
	local base = endpoint(pr)
	local id = type(comment) == "table" and tostring(comment.id or "") or ""
	if id == "__body__" then
		on_done(false, "Cannot delete the pull request description")
		return nil
	end
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
	local target = reactions_endpoint(base, pr, comment)
	if not target then
		on_done(false, "Invalid Forgejo comment")
		return nil
	end
	return service.request("POST", target, { content = key }, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
