local service = require("atlas.providers.gitea.forgejo.client").pulls
local pagination = require("atlas.pulls.providers.gitea.forgejo.api.pagination")
local mapper = require("atlas.pulls.providers.gitea.forgejo.api.mapper")
local request_scope = require("atlas.core.requests")
local json = require("atlas.core.json")

local M = {}

---@param value integer|nil
---@return integer|nil
local function positive_line(value)
	return value and value > 0 and value or nil
end

---@param pr PullRequest
---@return string|nil
function M.endpoint(pr)
	if type(pr) ~= "table" then
		return nil
	end
	local owner, repo = tostring(pr.repo_full_name or ""):match("^([^/]+)/([^/]+)$")
	local id = tostring(pr.id or "")
	if owner and id:match("^%d+$") then
		return string.format("/repos/%s/%s/pulls/%s", service.url_encode(owner), service.url_encode(repo), id)
	end
end

---@param pr PullRequest
---@param inline PullsInlineCommentPosition
---@return { base: string, path: string, new_line: integer|nil, old_line: integer|nil, start_line: integer|nil, commit_id: string }|nil, string|nil
function M.comment_context(pr, inline)
	local base = M.endpoint(pr)
	local path = type(inline) == "table" and tostring(inline.path or "") or ""
	local new_line = type(inline) == "table" and positive_line(inline.to) or nil
	local old_line = type(inline) == "table" and positive_line(inline.from) or nil
	local start_line = type(inline) == "table" and positive_line(new_line and inline.start_to or inline.start_from)
		or nil
	local commit_id = type(inline) == "table" and tostring(inline.commit_hash or "") or ""
	if commit_id == "" and type(pr) == "table" and type(pr.source) == "table" then
		commit_id = tostring(pr.source.commit_hash or "")
	end
	if not base or path == "" or (not new_line and not old_line) then
		return nil, "Invalid Forgejo inline comment position"
	end
	if commit_id == "" then
		return nil, "Missing source commit hash"
	end
	local context = {
		base = base,
		path = path,
		new_line = new_line,
		old_line = old_line,
		start_line = start_line,
		commit_id = commit_id,
	}
	return context, nil
end

---@param mapper table
---@param pr PullRequest
---@param raw_comment table
---@param commit_id string
---@param opts PullsAddCommentOpts|nil
---@param pending_body string|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_comment(mapper, pr, raw_comment, commit_id, opts, pending_body, on_done)
	local base = assert(M.endpoint(pr))
	local pending = type(opts) == "table" and opts.pending == true
	local target_review = type(opts) == "table" and opts.review or nil
	if not pending and type(target_review) == "table" and target_review.pending == true then
		on_done(nil, "Submit the pending review first")
		return nil
	end
	local requests = request_scope.new()
	requests.run(function(done)
		return service.request("POST", base .. "/reviews", {
			body = pending and pending_body or nil,
			event = pending and "PENDING" or "COMMENT",
			commit_id = commit_id,
			comments = { raw_comment },
		}, done)
	end, function(raw_review, err)
		if err then
			on_done(nil, err)
			return
		end
		local review_id = tostring(raw_review.id or "")
		if not review_id:match("^%d+$") then
			on_done(nil, "Invalid pull request review response")
			return
		end
		if pending and type(target_review) == "table" then
			target_review.id = review_id
			target_review.commit_hash = tostring(raw_review.commit_id or commit_id)
			target_review.pending = true
		end
		requests.run(function(done)
			return service.request("GET", string.format("%s/reviews/%s/comments", base, review_id), nil, done)
		end, function(raw, fetch_err)
			local newest, newest_id
			if not fetch_err and json.is_list(raw) then
				for _, value in ipairs(raw) do
					local id = type(value) == "table" and tonumber(value.id) or nil
					if id and (not newest_id or id > newest_id) then
						newest = value
						newest_id = id
					end
				end
			end
			local created = newest and mapper.to_comment(newest, raw_review) or nil
			if not created or not created.inline then
				on_done(nil, fetch_err or "Invalid pull request review comment response")
				return
			end
			on_done(created, nil)
		end)
	end)
	return requests
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param event "COMMENT"|"APPROVED"|"REQUEST_CHANGES"
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function submit(pr, review, event, body, on_done)
	local base = M.endpoint(pr)
	if not base then
		on_done(false, "Invalid Forgejo repository")
		return nil
	end
	body = tostring(body or "")
	if event == "REQUEST_CHANGES" and vim.trim(body) == "" then
		on_done(false, "Request changes body cannot be empty")
		return nil
	end
	local source = type(pr.source) == "table" and pr.source or {}
	local payload = {
		body = body,
		event = event,
		commit_id = tostring(source.commit_hash or ""),
	}
	if payload.commit_id == "" then
		payload.commit_id = nil
	end
	local review_id = type(review) == "table" and tostring(review.id or "") or ""
	local target = review_id:match("^%d+$") and (base .. "/reviews/" .. review_id) or (base .. "/reviews")
	if target ~= base .. "/reviews" then
		payload.commit_id = nil
	end
	return service.request("POST", target, payload, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
function M.submit_review(pr, review, body, on_done)
	return submit(pr, review, "COMMENT", body, on_done)
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
function M.approve(pr, review, body, on_done)
	return submit(pr, review, "APPROVED", body, on_done)
end

---@param pr PullRequest
---@param review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
function M.request_changes(pr, review, body, on_done)
	return submit(pr, review, "REQUEST_CHANGES", body, on_done)
end

---@param pr PullRequest
---@param _ table|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil, reviews: table[]|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(pr, _, on_done)
	local base = M.endpoint(pr)
	if not base then
		on_done(nil, "Invalid Forgejo repository")
		return nil
	end

	local requests = request_scope.new()
	-- TODO: Load inline-comment reactions lazily when the diff UI requests them.
	local function start_comments(review_id)
		return function(done)
			return service.request("GET", string.format("%s/reviews/%s/comments", base, review_id), nil, done)
		end
	end
	requests.run(function(done)
		return pagination.fetch_all(base .. "/reviews", nil, {
			invalid_response = "Invalid pull request reviews response",
			post_filtered = true,
		}, done)
	end, function(reviews, err)
		if err then
			on_done(nil, err)
			return
		end
		reviews = reviews or {}
		local starts = {}
		for index, review in ipairs(reviews) do
			local review_id = type(review) == "table" and tostring(review.id or "") or ""
			if not review_id:match("^%d+$") then
				on_done(nil, "Invalid pull request reviews response")
				return
			end
			if review.comments_count ~= 0 then
				starts[tostring(index)] = start_comments(review_id)
			end
		end
		requests.all(starts, function(values, errors)
			local comments = {}
			for index, review in ipairs(reviews) do
				local key = tostring(index)
				if starts[key] then
					local raw, comments_err = values[key], errors[key]
					if comments_err or not json.is_list(raw) then
						on_done(nil, comments_err or "Invalid pull request review comments response")
						return
					end
					for _, value in ipairs(raw) do
						local comment = mapper.to_comment(value, review)
						if not comment or not comment.inline then
							on_done(nil, "Invalid pull request review comments response")
							return
						end
						table.insert(comments, comment)
					end
				end
			end
			on_done(mapper.thread_comments(comments), nil, reviews)
		end)
	end)
	return requests
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	return fetch_comments(pr, opts, function(comments, err, raw_reviews)
		if err then
			on_done(nil, err)
			return
		end
		local pending, pending_id
		for _, raw in ipairs(raw_reviews or {}) do
			local id = tonumber(raw.id)
			if tostring(raw.state or ""):upper() == "PENDING" and id and (not pending_id or id > pending_id) then
				pending = raw
				pending_id = id
			end
		end
		local source = type(pr.source) == "table" and pr.source or {}
		local commit_hash = tostring((pending and pending.commit_id) or source.commit_hash or "")
		on_done({
			review = {
				id = pending and tostring(pending.id) or nil,
				commit_hash = commit_hash ~= "" and commit_hash or nil,
				pending = pending ~= nil,
			},
			comments = comments or {},
			tasks = {},
		}, nil)
	end)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
function M.fetch_context(pr, _opts, on_done)
	local authors, seen = {}, {}
	local function add(value)
		if type(value) ~= "table" then
			return
		end
		local key = tostring(value.id or "")
		if key == "" then
			key = tostring(value.username or value.nickname or value.name or ""):lower()
		end
		if key ~= "" and not seen[key] then
			seen[key] = true
			table.insert(authors, value)
		end
	end

	add(pr.author)
	for _, values in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
		for _, value in ipairs(values) do
			add(value)
		end
	end
	on_done({ authors = authors }, nil)
end

---@param pr PullRequest
---@param review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.start_review(pr, review, on_done)
	local base = M.endpoint(pr)
	local source = type(pr) == "table" and pr.source or nil
	local commit_id = type(source) == "table" and tostring(source.commit_hash or "") or ""
	if not base or type(review) ~= "table" or commit_id == "" then
		on_done(false, "Invalid Forgejo review")
		return nil
	end
	if review.pending == true and tostring(review.id or ""):match("^%d+$") then
		on_done(true, nil)
		return nil
	end
	return service.request("POST", base .. "/reviews", {
		body = "Pending review",
		event = "PENDING",
		commit_id = commit_id,
	}, function(raw, err)
		if err then
			on_done(false, err)
			return
		end
		local id = tostring(raw.id or "")
		if not id:match("^%d+$") then
			on_done(false, "Invalid pull request review response")
			return
		end
		review.id = id
		review.commit_hash = tostring(raw.commit_id or commit_id)
		review.pending = true
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
function M.discard_review(pr, review, on_done)
	local base = M.endpoint(pr)
	local review_id = type(review) == "table" and tostring(review.id or "") or ""
	if not base or type(review) ~= "table" or review.pending ~= true or not review_id:match("^%d+$") then
		on_done(false, "No pending Forgejo review")
		return nil
	end
	return service.request("DELETE", string.format("%s/reviews/%s", base, review_id), nil, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param content string
---@param inline PullsInlineCommentPosition
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(pr, content, inline, opts, on_done)
	if type(opts) == "function" then
		on_done = opts
		opts = nil
	end
	local context, err = M.comment_context(pr, inline)
	if not context then
		on_done(nil, err)
		return nil
	end

	local comment = { body = content, path = context.path }
	if context.start_line and context.start_line ~= (context.new_line or context.old_line) then
		comment.extra_lines_count = math.abs((context.new_line or context.old_line) - context.start_line)
	end
	local position = comment.extra_lines_count and context.start_line or (context.new_line or context.old_line)
	if context.new_line then
		comment.new_position = position
	else
		comment.old_position = position
	end

	local pending = type(opts) == "table" and opts.pending == true
	local pending_review = type(opts) == "table" and opts.review or nil
	local review_id = pending and type(pending_review) == "table" and tostring(pending_review.id or "") or ""
	if not review_id:match("^%d+$") then
		return M.create_comment(mapper, pr, comment, context.commit_id, opts, "Pending review", on_done)
	end

	return service.request(
		"POST",
		string.format("%s/reviews/%s/comments", context.base, review_id),
		comment,
		function(raw, request_err)
			local created = not request_err and mapper.to_comment(raw, { id = review_id, state = "PENDING" }) or nil
			if not created or not created.inline then
				on_done(nil, request_err or "Invalid pull request review comment response")
				return
			end
			on_done(created, nil)
		end
	)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(pr, comment, on_done)
	local base = M.endpoint(pr)
	local raw = type(comment) == "table" and comment._raw or nil
	local review_id = type(raw) == "table" and tostring(raw.review_id or "") or ""
	local comment_id = type(comment) == "table" and tostring(comment.id or "") or ""
	if not base or not review_id:match("^%d+$") or not comment_id:match("^%d+$") then
		on_done(false, "Invalid Forgejo review comment")
		return nil
	end
	local target = string.format("%s/reviews/%s/comments/%s", base, review_id, comment_id)
	return service.request("DELETE", target, nil, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
