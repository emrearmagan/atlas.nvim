local M = {}

local cli = require("atlas.providers.github.client")
local mapper = require("atlas.pulls.providers.github.api.mapper")

---@param entries PullsActivityEntry[]
---@return PullsActivityEntry[]
local function squash_commits(entries)
	local squashed = {}
	local run_start, run_count = nil, 0
	local function flush()
		if run_start ~= nil then
			run_start.label = string.format("added %d commit%s", run_count, run_count == 1 and "" or "s")
			run_start.kind = "update"
			table.insert(squashed, run_start)
			run_start, run_count = nil, 0
		end
	end
	for _, entry in ipairs(entries) do
		if entry.kind == "committed" then
			if run_start == nil then
				run_start = entry
				run_count = 1
			else
				run_count = run_count + 1
				run_start.date = entry.date or run_start.date
			end
		else
			flush()
			table.insert(squashed, entry)
		end
	end
	flush()
	return squashed
end

---@param pr PullRequest
---@param on_done fun(pages: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_timeline(pr, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh(
		{ "api", "--paginate", "--slurp", string.format("repos/%s/issues/%s/timeline", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch pull request timeline")
				return
			end
			on_done(result, nil)
		end,
		{
			action = "Fetch pull request timeline",
			repo = pr.repo_full_name,
			number = pr.id,
		}
	)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, _opts, on_done)
	return fetch_timeline(pr, function(pages, err)
		if not pages then
			on_done(nil, err)
			return
		end
		local entries = {}
		for _, page in ipairs(pages) do
			for _, item in ipairs(page) do
				if item.event ~= "commented" then
					local entry = mapper.to_activity(item)
					if entry then
						table.insert(entries, entry)
					end
				end
			end
		end
		on_done(squash_commits(entries), nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: PullsConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, _opts, on_done)
	return fetch_timeline(pr, function(result, err)
		if not result then
			on_done(nil, err)
			return
		end

		local dismissed_states = {}
		for _, page in ipairs(result) do
			for _, item in ipairs(page) do
				local dismissed = item.event == "review_dismissed" and item.dismissed_review or nil
				if dismissed and dismissed.review_id then
					dismissed_states[tostring(dismissed.review_id)] = tostring(dismissed.state or ""):lower()
				end
			end
		end

		local items, events = {}, {}
		for _, page in ipairs(result) do
			for _, item in ipairs(page) do
				local event_name = tostring(item.event or "")
				if event_name == "commented" then
					local comment = mapper.to_activity_comment(item)
					table.insert(items, {
						id = "comment:" .. tostring(comment.id),
						kind = "comment",
						created_on = comment.created_on,
						entity = comment,
					})
				else
					local review = nil
					if event_name == "reviewed" then
						review = mapper.to_conversation_review(item)
						if review then
							review.previous_state = dismissed_states[tostring(item.id or "")]
							table.insert(items, {
								id = "review:" .. tostring(review.id or review.submitted_on),
								kind = "review",
								created_on = review.submitted_on,
								entity = review,
							})
						end
					end
					local entry = nil
					if not (event_name == "reviewed" and review) then
						entry = mapper.to_activity(item)
					end
					if entry then
						table.insert(events, entry)
					end
				end
			end
		end

		for _, entry in ipairs(squash_commits(events)) do
			local actor_id = entry.actor and entry.actor.id or ""
			local id = table.concat({ entry.date or "", entry.kind or "", actor_id }, ":")
			table.insert(items, {
				id = "activity:" .. id,
				kind = "activity",
				created_on = entry.date or "",
				entity = entry,
			})
		end
		on_done(items, nil)
	end)
end

return M
