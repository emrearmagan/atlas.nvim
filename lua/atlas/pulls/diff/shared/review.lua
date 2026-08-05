local M = {}

---@class AtlasInitialReview
---@field comments PullsComment[]
---@field tasks PullsComment[]
---@field warnings string[]

---@class AtlasReviewOpenContext
---@field provider PullsProvider
---@field pr PullRequest
---@field current_user PullsUser|nil
---@field review_context { authors: PullsAuthor[] }|nil
---@field initial_review AtlasInitialReview|nil

---@class AtlasPreparedReviewContext : AtlasReviewOpenContext
---@field initial_review AtlasInitialReview

---@class AtlasReviewLoadOptions
---@field force_refresh boolean|nil

---@class AtlasReviewFetch
---@field label string
---@field start fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil
---@field apply fun(value: any)

---@param review AtlasReviewOpenContext
---@param options AtlasReviewLoadOptions
---@param on_done fun(result: AtlasPreparedReviewContext)
---@return { cancel: fun() }
function M.load(review, options, on_done)
	local provider = review.provider
	local core = provider.capabilities.core
	local reviews = provider.capabilities.reviews
	local previous = review.initial_review or {}
	local values = {
		current_user = review.current_user,
		review_context = review.review_context,
		comments = previous.comments or {},
		tasks = previous.tasks or {},
	}
	local fetch_opts = options.force_refresh and { force_refresh = true } or {}
	---@type AtlasReviewFetch[]
	local fetches = {}

	---@param label string
	---@param start fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil
	---@param apply fun(value: any)
	local function add(label, start, apply)
		table.insert(fetches, { label = label, start = start, apply = apply })
	end

	if reviews and reviews.fetch_review_context then
		add("review context", function(done)
			return reviews.fetch_review_context(review.pr, fetch_opts, done)
		end, function(value)
			values.review_context = value or values.review_context
		end)
	end
	if reviews then
		add("comments", function(done)
			return reviews.fetch_comments(review.pr, fetch_opts, done)
		end, function(value)
			values.comments = value or {}
		end)
	end
	if reviews and reviews.fetch_tasks then
		add("tasks", function(done)
			return reviews.fetch_tasks(review.pr, fetch_opts, done)
		end, function(value)
			values.tasks = value or {}
		end)
	end
	if not values.current_user then
		add("current user", function(done)
			return core.fetch_user(done)
		end, function(value)
			values.current_user = value or values.current_user
		end)
	end

	local cancelled = false
	local finished = false
	local pending = #fetches
	local handles = {}
	local warnings = {}

	local function finish()
		if cancelled or finished or pending > 0 then
			return
		end
		finished = true
		on_done({
			provider = provider,
			pr = review.pr,
			current_user = values.current_user,
			review_context = values.review_context,
			initial_review = {
				comments = values.comments,
				tasks = values.tasks,
				warnings = warnings,
			},
		})
	end

	for _, fetch in ipairs(fetches) do
		local item = fetch
		local settled = false
		local handle = item.start(function(value, err)
			if cancelled or settled then
				return
			end
			settled = true
			if err then
				table.insert(warnings, "Unable to load " .. item.label .. ": " .. tostring(err))
			else
				item.apply(value)
			end
			pending = pending - 1
			finish()
		end)
		if handle and not settled then
			table.insert(handles, handle)
		end
	end

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

return M
