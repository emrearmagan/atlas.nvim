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

---@class AtlasReviewPreparation
---@field review AtlasPreparedReviewContext|nil

---@class AtlasReviewPrepareOptions
---@field review AtlasReviewOpenContext|nil
---@field fetch_branches (fun(pr: PullRequest|nil, on_done: fun(err: string|nil)): { cancel: fun() }|nil)|nil
---@field force_refresh boolean|nil
---@field refresh_pull_request boolean|nil
---@field on_progress (fun(message: string))|nil

---@class AtlasReviewFetch
---@field label string
---@field start fun(done: fun(value: any, err: string|nil)): { cancel: fun() }|nil
---@field apply fun(value: any)
---@field warning string|nil

---@param options AtlasReviewPrepareOptions
---@param on_done fun(result: AtlasReviewPreparation|nil, err: string|nil)
---@return { cancel: fun() }
function M.run(options, on_done)
	local cancelled = false
	local finished = false
	local requests = {}
	local review = options.review

	local function cancel_requests()
		for request in pairs(requests) do
			requests[request] = nil
			if request.cancel then
				pcall(request.cancel)
			end
		end
	end

	---@param result AtlasReviewPreparation|nil
	---@param err string|nil
	local function finish(result, err)
		if cancelled or finished then
			return
		end
		finished = true
		cancel_requests()
		on_done(result, err)
	end

	---@param message string
	local function progress(message)
		if not cancelled and not finished and options.on_progress then
			pcall(options.on_progress, message)
		end
	end

	---@param starter fun(done: fun(...)): { cancel: fun() }|nil
	---@param complete fun(...)
	---@param failed fun(err: string)
	local function start(starter, complete, failed)
		if cancelled or finished then
			return
		end

		local request = {}
		local settled = false
		requests[request] = true

		local function done(...)
			if settled then
				return
			end
			settled = true
			requests[request] = nil
			if not cancelled and not finished then
				complete(...)
			end
		end

		local ok, handle = pcall(starter, done)
		if not ok then
			if not settled then
				settled = true
				requests[request] = nil
				if not cancelled and not finished then
					failed(tostring(handle))
				end
			end
			return
		end

		if (settled or cancelled or finished) and handle then
			pcall(handle.cancel)
		elseif requests[request] and handle then
			request.cancel = handle.cancel
		end
	end

	local function prepare_review()
		if not review then
			finish({ review = nil }, nil)
			return
		end

		local provider = review.provider
		local previous = review.initial_review or {}
		local values = {
			current_user = review.current_user,
			review_context = review.review_context,
			comments = vim.deepcopy(previous.comments or {}),
			tasks = vim.deepcopy(previous.tasks or {}),
		}
		local fetch_opts = options.force_refresh == true and { force_refresh = true } or {}
		---@type AtlasReviewFetch[]
		local fetches = {}

		if provider.fetch_review_context then
			table.insert(fetches, {
				label = "review context",
				start = function(done)
					return provider.fetch_review_context(review.pr, fetch_opts, done)
				end,
				apply = function(value)
					values.review_context = value or values.review_context
				end,
			})
		end
		table.insert(fetches, {
			label = "comments",
			start = function(done)
				return provider.fetch_comments(review.pr, fetch_opts, done)
			end,
			apply = function(value)
				values.comments = value or {}
			end,
		})
		if provider.fetch_tasks then
			table.insert(fetches, {
				label = "tasks",
				start = function(done)
					return provider.fetch_tasks(review.pr, fetch_opts, done)
				end,
				apply = function(value)
					values.tasks = value or {}
				end,
			})
		end
		if not values.current_user then
			table.insert(fetches, {
				label = "current user",
				start = function(done)
					return provider.fetch_user(done)
				end,
				apply = function(value)
					values.current_user = value or values.current_user
				end,
			})
		end

		---@param warnings string[]
		local function complete(warnings)
			---@type AtlasPreparedReviewContext
			local prepared = {
				provider = provider,
				pr = review.pr,
				current_user = vim.deepcopy(values.current_user),
				review_context = vim.deepcopy(values.review_context),
				initial_review = {
					comments = vim.deepcopy(values.comments),
					tasks = vim.deepcopy(values.tasks),
					warnings = vim.deepcopy(warnings),
				},
			}
			finish({ review = prepared }, nil)
		end

		progress(options.force_refresh and "Refreshing review..." or "Loading review...")
		local pending = #fetches
		for _, fetch in ipairs(fetches) do
			local function fetched(value, err)
				if err then
					fetch.warning = "Unable to load " .. fetch.label .. ": " .. tostring(err)
				else
					fetch.apply(value)
				end
				pending = pending - 1
				if pending == 0 then
					local warnings = {}
					for _, candidate in ipairs(fetches) do
						if candidate.warning then
							table.insert(warnings, candidate.warning)
						end
					end
					complete(warnings)
				end
			end

			start(fetch.start, fetched, function(start_err)
				fetched(nil, start_err)
			end)
		end
	end

	local function prepare_branches()
		if not options.fetch_branches then
			prepare_review()
			return
		end
		progress("Fetching remote branches...")
		start(function(done)
			return options.fetch_branches(review and review.pr or nil, done)
		end, function(err)
			if err then
				finish(nil, tostring(err))
				return
			end
			prepare_review()
		end, function(start_err)
			finish(nil, start_err)
		end)
	end

	local function prepare_pullrequest()
		if not options.refresh_pull_request or not review then
			prepare_branches()
			return
		end
		progress("Refreshing pull request...")
		start(function(done)
			return review.provider.fetch_pullrequest(review.pr, { force_load = true }, done)
		end, function(pr, err)
			if not pr then
				finish(nil, tostring(err or "Unable to refresh pull request"))
				return
			end
			review = {
				provider = review.provider,
				pr = pr,
				current_user = review.current_user,
				review_context = review.review_context,
				initial_review = review.initial_review,
			}
			prepare_branches()
		end, function(start_err)
			finish(nil, "Unable to refresh pull request: " .. start_err)
		end)
	end

	local handle = {
		cancel = function()
			if cancelled or finished then
				return
			end
			cancelled = true
			cancel_requests()
		end,
	}

	prepare_pullrequest()

	return handle
end

return M
