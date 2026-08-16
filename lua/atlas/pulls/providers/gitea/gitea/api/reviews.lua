local service = require("atlas.providers.gitea.gitea.client").pulls
local pagination = require("atlas.pulls.providers.gitea.gitea.api.pagination")
local mapper = require("atlas.pulls.providers.gitea.gitea.api.mapper")

local M = {}

---@param value any
---@return boolean
local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	for key in pairs(value) do
		if key ~= "__http_status" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
			return false
		end
	end
	return true
end

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
	local cancelled, active = false, nil
	active = service.request("POST", base .. "/reviews", {
		body = pending and pending_body or nil,
		event = pending and "PENDING" or "COMMENT",
		commit_id = commit_id,
		comments = { raw_comment },
	}, function(raw_review, err)
		local review_id = type(raw_review) == "table" and tostring(raw_review.id or "") or ""
		if cancelled then
			return
		end
		if err or not review_id:match("^%d+$") then
			on_done(nil, err or "Invalid pull request review response")
			return
		end
		if pending and type(target_review) == "table" then
			target_review.id = review_id
			target_review.commit_hash = tostring(raw_review.commit_id or commit_id)
			target_review.pending = true
		end
		active = service.request(
			"GET",
			string.format("%s/reviews/%s/comments", base, review_id),
			nil,
			function(raw, fetch_err)
				if cancelled then
					return
				end
				local newest, newest_id
				if not fetch_err and is_list(raw) then
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
			end
		)
	end)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
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
	body = tostring(body or "")
	if event == "COMMENT" and vim.trim(body) == "" then
		on_done(false, "Review body cannot be empty")
		return nil
	end
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
		on_done(nil, "Invalid Gitea repository")
		return nil
	end

	local cancelled, active = false, nil
	local function fetch_reactions(comments, index, on_reactions_done)
		if cancelled then
			return
		end
		local comment = comments[index]
		if not comment then
			on_reactions_done()
			return
		end
		local id = tostring(comment.id or "")
		local repo = base:match("^(.-)/pulls/%d+$")
		if not repo or not id:match("^%d+$") then
			fetch_reactions(comments, index + 1, on_reactions_done)
			return
		end
		active = service.request(
			"GET",
			string.format("%s/issues/comments/%s/reactions", repo, id),
			nil,
			function(values, err)
				if cancelled then
					return
				end
				if not err and is_list(values) then
					comment.reactions = mapper.reaction_counts(values)
				end
				fetch_reactions(comments, index + 1, on_reactions_done)
			end
		)
	end
	local function fetch_comments(reviews, index, comments)
		if cancelled then
			return
		end
		local review = reviews[index]
		if review == nil then
			fetch_reactions(comments, 1, function()
				on_done(mapper.thread_comments(comments), nil, reviews)
			end)
			return
		end
		local review_id = type(review) == "table" and tostring(review.id or "") or ""
		if not review_id:match("^%d+$") then
			on_done(nil, "Invalid pull request reviews response")
			return
		end
		if review.comments_count == 0 then
			fetch_comments(reviews, index + 1, comments)
			return
		end

		active = service.request(
			"GET",
			string.format("%s/reviews/%s/comments", base, review_id),
			nil,
			function(raw, err)
				if cancelled then
					return
				end
				if err or not is_list(raw) then
					on_done(nil, err or "Invalid pull request review comments response")
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
				fetch_comments(reviews, index + 1, comments)
			end
		)
	end

	active = pagination.fetch_all(base .. "/reviews", nil, {
		invalid_response = "Invalid pull request reviews response",
		post_filtered = true,
	}, function(reviews, err)
		if cancelled then
			return
		end
		if err then
			on_done(nil, err)
			return
		end
		fetch_comments(reviews or {}, 1, {})
	end)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local cancelled, active = false, nil
	local current_user
	local function load_comments()
		active = fetch_comments(pr, opts, function(comments, err, raw_reviews)
			if cancelled then
				return
			end
			if err then
				on_done(nil, err)
				return
			end
			local pending
			for _, raw in ipairs(raw_reviews or {}) do
				local raw_user = type(raw) == "table" and raw.user or nil
				local state = type(raw) == "table" and tostring(raw.state or ""):upper() or ""
				local raw_id = type(raw_user) == "table" and tostring(raw_user.id or "") or ""
				local current_id = type(current_user) == "table" and tostring(current_user.id or "") or ""
				local raw_login = type(raw_user) == "table" and tostring(raw_user.login or ""):lower() or ""
				local current_login = type(current_user) == "table" and tostring(current_user.login or ""):lower() or ""
				local same_user = type(raw_user) == "table"
					and type(current_user) == "table"
					and (
						(raw_id ~= "" and current_id ~= "" and raw_id == current_id)
						or (raw_login ~= "" and current_login ~= "" and raw_login == current_login)
					)
				if same_user and state == "PENDING" and tostring(raw.id or ""):match("^%d+$") then
					if not pending or raw.id > pending.id then
						pending = raw
					end
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

	active = service.request("GET", "/user", nil, function(raw, err)
		if cancelled then
			return
		end
		if err or type(raw) ~= "table" then
			on_done(nil, err or "Invalid Gitea user response")
			return
		end
		current_user = raw
		load_comments()
	end)
	return {
		cancel = function()
			cancelled = true
			if active and active.cancel then
				active.cancel()
			end
		end,
	}
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
		on_done(false, "Invalid Gitea review")
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
		local id = type(raw) == "table" and tostring(raw.id or "") or ""
		if err or not id:match("^%d+$") then
			on_done(false, err or "Invalid pull request review response")
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
	local position = context.new_line or context.old_line
	if context.start_line and context.start_line ~= position then
		-- TODO: Send the full range once Gitea supports multi-line review comments.
		position = context.start_line
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
	local comment_id = type(comment) == "table" and tostring(comment.id or "") or ""
	if not base or not comment_id:match("^%d+$") then
		on_done(false, "Invalid Gitea review comment")
		return nil
	end
	return service.request("DELETE", string.format("%s/issues/comments/%s", base, comment_id), nil, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
