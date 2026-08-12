local M = {}

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
function M.cancel_actions(session)
	local requests = session.review_action_requests
	session.review_action_requests = {}
	session.review_generation = session.review_generation + 1
	for _, handle in ipairs(requests) do
		handle.cancel()
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
	local values = {
		current_user = context.current_user,
		context = context.context,
		state = context.state,
		comments = context.comments,
		tasks = context.tasks,
	}
	local options = force_refresh and { force_refresh = true } or {}
	local cancelled = false
	local pending = 0
	local started = false
	local handles = {}
	local warnings = {}
	local function finish()
		if cancelled or not started or pending > 0 then
			return
		end
		local review = {
			provider = context.provider,
			pr = context.pr,
			current_user = values.current_user,
			context = values.context,
			state = values.state,
			comments = values.comments,
			tasks = values.tasks,
		}
		resolve_items(review)
		on_done(review, warnings)
	end

	---@param name string
	---@param start fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil
	---@param apply fun(value: any)
	local function fetch(name, start, apply)
		pending = pending + 1
		local done = false
		local handle = start(function(value, err)
			if cancelled or done then
				return
			end
			done = true
			if err then
				warnings[#warnings + 1] = "Unable to load " .. name .. ": " .. tostring(err)
			else
				apply(value)
			end
			pending = pending - 1
			finish()
		end)
		if handle and not done then
			handles[#handles + 1] = handle
		end
	end

	local reviews = context.provider.capabilities.reviews
	if reviews and reviews.fetch_review_context then
		fetch("review context", function(done)
			return reviews.fetch_review_context(context.pr, options, done)
		end, function(value)
			values.context = value or values.context
		end)
	end
	if reviews then
		fetch("review", function(done)
			return reviews.fetch(context.pr, options, done)
		end, function(value)
			if value then
				values.state = value.review
				values.comments = value.comments
				values.tasks = value.tasks
			end
		end)
	end
	if not values.current_user then
		fetch("current user", function(done)
			return context.provider.capabilities.core.fetch_user(done)
		end, function(value)
			values.current_user = value or values.current_user
		end)
	end
	started = true
	finish()
	return {
		cancel = function()
			cancelled = true
			for _, handle in ipairs(handles) do
				handle.cancel()
			end
		end,
	}
end

---@param session AtlasDiffSession
---@param comment PullsComment|nil
---@return AtlasReviewActionContext|nil
function M.action_context(session, comment)
	local review = session.review
	if not review or session.review_request then
		return nil
	end
	local generation = session.review_generation
	local function active()
		return not session.closed and session.review == review and session.review_generation == generation
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
			if active() then
				notify(session, level, message, duration)
			end
		end,
		active = active,
		track = function(handle)
			if not handle then
				return function() end
			end
			if not active() then
				handle.cancel()
				return function() end
			end
			table.insert(session.review_action_requests, handle)
			return function()
				for index, request in ipairs(session.review_action_requests) do
					if request == handle then
						table.remove(session.review_action_requests, index)
						return
					end
				end
			end
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
	M.cancel_actions(session)
	local generation = session.review_generation
	notify(session, "loading", "Refreshing review...")
	local finished = false
	local request = M.load(
		{
			provider = review.provider,
			pr = review.pr,
			current_user = review.current_user,
			context = review.context,
			state = review.state,
			comments = review.comments,
			tasks = review.tasks,
		},
		true,
		function(loaded, warnings)
			finished = true
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
		end
	)
	if not finished then
		session.review_request = request
	end
end

return M
