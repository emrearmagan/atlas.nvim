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
				comments = review.comments,
				tasks = review.tasks,
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
function M.invalidate(session)
	session.review_generation = session.review_generation + 1
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
		local current_user = context.current_user
		if not errors.current_user and values.current_user then
			current_user = values.current_user
		end
		local review_context = context.context
		if not errors.review_context and values.review_context then
			review_context = values.review_context
		end
		local state = context.state
		local comments = context.comments
		local tasks = context.tasks
		if not errors.review and values.review then
			state = values.review.review
			comments = values.review.comments
			tasks = values.review.tasks
		end
		local review = {
			provider = context.provider,
			pr = context.pr,
			current_user = current_user,
			context = review_context,
			state = state,
			comments = comments,
			tasks = tasks,
		}
		resolve_items(review)
		on_done(review, warnings)
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
	local data = {
		review = review.state,
		comments = review.comments,
		tasks = review.tasks,
	}
	return {
		provider = review.provider,
		pr = review.pr,
		current_user = review.current_user,
		data = data,
		items = comment and comment.is_task and review.tasks or review.comments,
		completion = comment_completion(review),
		notify = function(level, message, duration)
			notify(session, level, message, duration)
		end,
	}
end

---@param session AtlasDiffSession
---@param data PullsReviewData
function M.apply_action_data(session, data)
	local review = session.review
	if not review then
		return
	end
	review.state = data.review
	review.comments = data.comments
	review.tasks = data.tasks
	resolve_items(review)
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
	M.invalidate(session)
	local generation = session.review_generation
	notify(session, "loading", "Refreshing review...")
	local pending = request_scope.new()
	session.review_request = pending
	pending.run(function(done)
		return M.load({
			provider = review.provider,
			pr = review.pr,
			current_user = review.current_user,
			context = review.context,
			state = review.state,
			comments = review.comments,
			tasks = review.tasks,
		}, true, done)
	end, function(loaded, warnings)
		session.review_request = nil
		if session.closed or session.review_generation ~= generation then
			return
		end
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
