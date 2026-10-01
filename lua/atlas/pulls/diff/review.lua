local M = {}

local request_scope = require("atlas.core.requests")

---@param review AtlasDiffReview
---@return (fun(text: string): string)|nil
function M.comment_formatter(review)
	local comments = review.provider.capabilities.comments
	if not comments or not comments.comment_formatter then
		return nil
	end

	return comments.comment_formatter({
		pr = review.pr,
		data = review.data,
		review_context = review.context,
	})
end

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(session, level, message, duration)
	if session.notify then
		session.notify(level, message, duration)
	end
end

---@param context AtlasDiffReview
---@param on_done fun(review: AtlasDiffReview, warnings: string[])
---@return { cancel: fun() }
local function load(context, on_done)
	local options = { force_refresh = true }
	local starts = {}
	local reviews = context.provider.capabilities.reviews
	if reviews and reviews.fetch_review_context then
		starts.review_context = function(done)
			return reviews.fetch_review_context(context.pr, options, done)
		end
	end
	if reviews then
		starts.review = function(done)
			return reviews.fetch(context.pr, options, done)
		end
	end
	local users = context.provider.capabilities.users
	if not context.current_user and users then
		starts.current_user = users.fetch_user
	end

	local pending = request_scope.new()
	pending.all(starts, function(values, errors)
		local warnings = {}
		if errors.review_context then
			warnings[#warnings + 1] = "Unable to load review context: " .. tostring(errors.review_context)
		end
		if errors.review then
			warnings[#warnings + 1] = "Unable to load review: " .. tostring(errors.review)
		end
		if errors.current_user then
			warnings[#warnings + 1] = "Unable to load current user: " .. tostring(errors.current_user)
		end
		if not errors.current_user and values.current_user then
			context.current_user = values.current_user
		end
		if values.review_context then
			context.context = values.review_context
		end
		if not errors.review and values.review then
			context.data = values.review
		end
		on_done(context, warnings)
	end)
	return pending
end

---@param provider PullsProvider
---@param pr PullRequest
---@param current_user AtlasUser|nil
---@param on_done fun(review: AtlasDiffReview, warnings: string[])
---@return { cancel: fun() }
function M.load(provider, pr, current_user, on_done)
	return load({
		provider = provider,
		pr = pr,
		current_user = current_user,
		context = nil,
		data = {
			review = { pending = false },
			comments = {},
			tasks = {},
			reviewers = {},
			history = {},
		},
	}, on_done)
end

---@param session AtlasDiffSession
---@param comment PullsComment|nil
---@return AtlasReviewActionContext|nil
function M.action_context(session, comment)
	local review = session.review
	if not review or session.review_request then
		return nil
	end
	return {
		provider = review.provider,
		pr = review.pr,
		current_user = review.current_user,
		data = review.data,
		items = comment and comment.is_task and review.data.tasks or review.data.comments,
		review_context = review.context,
		notify = function(level, message, duration)
			notify(session, level, message, duration)
		end,
	}
end

---@param session AtlasDiffSession
---@param path string
---@param reviewed boolean
function M.set_file_reviewed(session, path, reviewed)
	if session.review_request then
		return
	end
	session.reviewed_files[path] = reviewed or nil
	local current_review = session.review
	local reviews = current_review and current_review.provider.capabilities.reviews
	if not reviews or not reviews.set_file_reviewed then
		return
	end
	reviews.set_file_reviewed(current_review.pr, path, reviewed, function(ok, err)
		if not ok then
			notify(session, "error", "Unable to update reviewed file: " .. tostring(err))
		end
	end)
end

---@param session AtlasDiffSession
function M.reload(session)
	local review = session.review
	if not review then
		return
	end
	if session.review_request then
		session.review_request.cancel()
	end
	notify(session, "loading", "Refreshing review...")
	local pending = request_scope.new()
	session.review_request = pending
	pending.run(function(done)
		return load(review, done)
	end, function(loaded, warnings)
		session.review_request = nil
		session.review = loaded
		if loaded.context and loaded.context.reviewed_files then
			session.reviewed_files = loaded.context.reviewed_files
		end
		session:render()
		if #warnings > 0 then
			notify(session, "warn", table.concat(warnings, "; "))
		else
			notify(session, "success", "Review refreshed", 1200)
		end
	end)
end

return M
