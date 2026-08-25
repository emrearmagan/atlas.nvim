local service = require("atlas.providers.gitea.client")
local pagination = require("atlas.providers.gitea.pagination")
local mapper = require("atlas.pulls.providers.gitea.api.mapper")
local request_scope = require("atlas.core.requests")

local M = {}

---@param value integer|nil
---@return integer|nil
local function positive_line(value)
	return value and value > 0 and value or nil
end

---@param pr PullRequest
---@return string|nil
function M.endpoint(pr)
	local owner, repo = pr.repo_full_name:match("^([^/]+)/([^/]+)$")
	local id = tostring(pr.id)
	if owner and id:match("^%d+$") then
		return string.format("/repos/%s/%s/pulls/%s", service.url_encode(owner), service.url_encode(repo), id)
	end
end

---@param pr PullRequest
---@param inline PullsInlineCommentPosition
---@return { base: string, path: string, new_line: integer|nil, old_line: integer|nil, start_line: integer|nil, commit_id: string }|nil, string|nil
function M.comment_context(pr, inline)
	local base = M.endpoint(pr)
	local path = inline.path
	local new_line = positive_line(inline.to)
	local old_line = positive_line(inline.from)
	local start_line = positive_line(new_line and inline.start_to or inline.start_from)
	local commit_id = tostring(inline.commit_hash or "")
	if commit_id == "" then
		commit_id = pr.source.commit_hash
	end
	if not base or path == "" or (not new_line and not old_line) then
		return nil, "Invalid Gitea inline comment position"
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

---@param comment_mapper table
---@param pr PullRequest
---@param raw_comment table
---@param commit_id string
---@param opts PullsAddCommentOpts|nil
---@param pending_body string|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_comment(comment_mapper, pr, raw_comment, commit_id, opts, pending_body, on_done)
	local base = assert(M.endpoint(pr))
	local pending = opts and opts.pending == true or false
	local target_review = opts and opts.review or nil
	if not pending and target_review and target_review.pending == true then
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
		local review_id = tostring(raw_review.id)
		if pending and target_review then
			target_review.id = review_id
			target_review.commit_hash = tostring(raw_review.commit_id)
			target_review.pending = true
		end
		requests.run(function(done)
			return service.request("GET", string.format("%s/reviews/%s/comments", base, review_id), nil, done)
		end, function(raw, fetch_err)
			if fetch_err then
				on_done(nil, fetch_err)
				return
			end
			local newest, newest_id
			for _, value in ipairs(raw) do
				local id = tonumber(value.id)
				if not newest_id or id > newest_id then
					newest = value
					newest_id = id
				end
			end
			on_done(comment_mapper.to_comment(newest, raw_review), nil)
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
		on_done(false, "Invalid Gitea repository")
		return nil
	end
	body = tostring(body)
	if event == "COMMENT" and vim.trim(body) == "" then
		on_done(false, "Review body cannot be empty")
		return nil
	end
	if event == "REQUEST_CHANGES" and vim.trim(body) == "" then
		on_done(false, "Request changes body cannot be empty")
		return nil
	end
	local payload = {
		body = body,
		event = event,
		commit_id = pr.source.commit_hash,
	}
	if payload.commit_id == "" then
		payload.commit_id = nil
	end
	local review_id = review and tostring(review.id or "") or ""
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
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil, reviews: table[]|nil)
---@return { cancel: fun() }|nil
local function fetch_comments(pr, on_done)
	local base = M.endpoint(pr)
	if not base then
		on_done(nil, "Invalid Gitea repository")
		return nil
	end

	local requests = request_scope.new()
	requests.run(function(done)
		return pagination.fetch_all(base .. "/reviews", nil, nil, done, {
			action = string.format("Fetch %s#%s reviews", pr.repo_full_name, pr.id),
			repo = pr.repo_full_name,
			pr_id = pr.id,
		})
	end, function(reviews, err)
		if err then
			on_done(nil, err)
			return
		end

		local starts = {}
		for _, review in ipairs(reviews) do
			local review_id = tonumber(review.id)
			if review_id and (tonumber(review.comments_count) or 0) > 0 then
				local endpoint = string.format("%s/reviews/%s/comments", base, review_id)
				starts[tostring(review_id)] = function(done)
					return service.request("GET", endpoint, nil, done, {
						action = string.format("Fetch %s#%s review %s comments", pr.repo_full_name, pr.id, review_id),
						repo = pr.repo_full_name,
						pr_id = pr.id,
						review_id = review_id,
					})
				end
			end
		end

		-- TODO: How the fuck do we get all Gitea review comments without one
		-- request per comment-bearing review? There is no bulk endpoint.
		requests.all(starts, function(values, errors)
			local comments = {}
			local fetched = false
			local first_error
			for _, review in ipairs(reviews) do
				local key = tostring(review.id)
				if starts[key] then
					local raw = values[key]
					if raw then
						fetched = true
						table.sort(raw, function(a, b)
							local a_created = tostring(a.created_at or "")
							local b_created = tostring(b.created_at or "")
							if a_created ~= b_created then
								return a_created < b_created
							end
							return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
						end)
						-- Gitea drops the reply parent ID, so stitch comments on the same review position back into a thread.
						local roots = {}
						for _, value in ipairs(raw) do
							local comment = mapper.to_comment(value, review)
							local inline = comment.inline
							local side = inline and (inline.to and "RIGHT" or inline.from and "LEFT") or nil
							local line = inline and (inline.to or inline.from) or nil
							if side and line then
								local thread = table.concat({ inline.path, side, tostring(line) }, "\0")
								comment.parent_id = roots[thread]
								roots[thread] = roots[thread] or comment.id
							end
							table.insert(comments, comment)
						end
					elseif not first_error then
						first_error = errors[key]
					end
				end
			end
			if next(starts) and not fetched and first_error then
				on_done(nil, first_error, reviews)
				return
			end
			on_done(comments, nil, reviews)
		end)
	end)
	return requests
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, _opts, on_done)
	return fetch_comments(pr, function(comments, err, raw_reviews)
		if err then
			on_done(nil, err)
			return
		end
		local pending, pending_id
		for _, raw in ipairs(raw_reviews) do
			local id = tonumber(raw.id)
			if tostring(raw.state or ""):upper() == "PENDING" and id and (not pending_id or id > pending_id) then
				pending = raw
				pending_id = id
			end
		end
		local commit_hash = tostring((pending and pending.commit_id) or pr.source.commit_hash)
		local metadata = mapper.to_review_data(pr, raw_reviews)
		on_done({
			review = {
				id = pending and tostring(pending.id) or nil,
				commit_hash = commit_hash ~= "" and commit_hash or nil,
				pending = pending ~= nil,
			},
			comments = comments,
			tasks = {},
			reviewers = metadata.reviewers,
			history = metadata.history,
		}, nil)
	end)
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
function M.fetch_context(pr, _opts, on_done)
	local candidates, seen = {}, {}
	---@param value PullsAuthor|PullsReviewer
	local function add(value)
		local key = value.id
		if key ~= "" and not seen[key] then
			seen[key] = true
			table.insert(candidates, value)
		end
	end

	add(pr.author)
	for _, value in ipairs(pr.reviewers or {}) do
		add(value)
	end
	on_done({ mention_candidates = candidates }, nil)
end

---@param pr PullRequest
---@param review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
function M.discard_review(pr, review, on_done)
	local base = M.endpoint(pr)
	local review_id = tostring(review.id or "")
	if not base or review.pending ~= true or not review_id:match("^%d+$") then
		on_done(false, "No pending Gitea review")
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
	local context, err = M.comment_context(pr, inline)
	if not context then
		on_done(nil, err)
		return nil
	end

	local comment = { body = content, path = context.path }
	local position = context.new_line or context.old_line
	if context.start_line and context.start_line ~= position then
		on_done(nil, "Gitea does not support multi-line review comments")
		return nil
	end
	if context.new_line then
		comment.new_position = position
	else
		comment.old_position = position
	end
	return M.create_comment(mapper, pr, comment, context.commit_id, opts, "Pending review", on_done)
end

---@param pr PullRequest
---@param comment PullsComment
---@param on_done fun(ok: boolean, err: string|nil)
function M.delete(pr, comment, on_done)
	local pull = M.endpoint(pr)
	local base = pull and pull:match("^(.-)/pulls/%d+$") or nil
	local comment_id = tostring(comment.id)
	if not base or not comment_id:match("^%d+$") then
		on_done(false, "Invalid Gitea review comment")
		return nil
	end
	return service.request("DELETE", string.format("%s/issues/comments/%s", base, comment_id), nil, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
