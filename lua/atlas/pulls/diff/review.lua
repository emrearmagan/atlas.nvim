local M = {}

local request_scope = require("atlas.core.requests")

---@param review AtlasDiffReview
---@return AtlasMarkdownCompletionProvider|nil
local function comment_completion(review)
	local comments = review.provider.capabilities.comments
	return comments
			and comments.comment_completion
			and comments.comment_completion({
				pr = review.pr,
				comments = review.data.comments,
				tasks = review.data.tasks,
				reviewers = review.data.reviewers,
				review_context = review.context,
			})
		or nil
end

---@param review AtlasDiffReview
local function resolve_items(review)
	local completion = comment_completion(review)
	if completion and completion.resolve_items then
		completion.resolve_items()
	end
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
---@param force_refresh boolean
---@param on_done fun(review: AtlasDiffReview, warnings: string[])
---@return { cancel: fun() }
function M.load(context, force_refresh, on_done)
	local options = force_refresh and { force_refresh = true } or {}
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
	if not context.current_user then
		starts.current_user = function(done)
			return context.provider.capabilities.core.fetch_user(done)
		end
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
		if not errors.review_context and values.review_context then
			context.context = values.review_context
		end
		if not errors.review and values.review then
			context.data = values.review
		end
		resolve_items(context)
		on_done(context, warnings)
	end)
	return pending
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
		completion = comment_completion(review),
		notify = function(level, message, duration)
			notify(session, level, message, duration)
		end,
	}
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
		return M.load(review, true, done)
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
