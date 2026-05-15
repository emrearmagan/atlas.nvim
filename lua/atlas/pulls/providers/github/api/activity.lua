local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")
local mapper = require("atlas.pulls.providers.github.api.mapper")

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	return M.fetch_conversation(pr, nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err)
			return
		end
		on_done(result.events or {}, nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: { comments: PullsComment[], events: PullsActivityEntry[] }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/issues/%s/timeline", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch conversation")
				return
			end

			local conversation = { comments = {}, events = {} }
			for _, item in ipairs(result) do
				local event_name = type(item) == "table" and tostring(item.event or "") or ""
				if event_name == "commented" then
					table.insert(conversation.comments, mapper.to_activity_comment(item))
				elseif event_name == "reviewed" then
					local entry = mapper.to_activity(item)
					if entry then
						table.insert(conversation.events, entry)
					end
				else
					local entry = mapper.to_activity(item)
					if entry then
						table.insert(conversation.events, entry)
					end
				end
			end

			-- Squash consecutive "committed" entries into "added N commits"
			local squashed = {}
			local run_start, run_count = nil, 0
			local function flush()
				if run_start ~= nil then
					run_start.content_raw = string.format("added %d commit%s", run_count, run_count == 1 and "" or "s")
					run_start.kind = "update"
					table.insert(squashed, run_start)
					run_start, run_count = nil, 0
				end
			end
			for _, e in ipairs(conversation.events) do
				if e.kind == "committed" then
					if run_start == nil then
						run_start = e
						run_count = 1
					else
						run_count = run_count + 1
						run_start.date = e.date or run_start.date
					end
				else
					flush()
					table.insert(squashed, e)
				end
			end
			flush()
			conversation.events = squashed

			on_done(conversation, nil)
		end,
		{
			action = "Fetch conversation",
			repo = pr.repo_full_name,
			number = pr.id,
		}
	)
end

return M
