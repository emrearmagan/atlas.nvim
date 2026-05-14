local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")

---@param value any
---@return string
local function body_text(value)
	if value == nil or value == vim.NIL then
		return ""
	end
	return tostring(value)
end

---@param login string
---@return PullsAuthor|nil
local function actor_from_login(login)
	if login == nil or login == "" then
		return nil
	end
	return { name = login, id = "", username = login, nickname = login }
end

---@param item table
---@return PullsActivityEntry|nil
local function normalize_event(item)
	local event = tostring(item.event or "")
	local actor_login = (type(item.actor) == "table" and tostring(item.actor.login or ""))
		or (type(item.user) == "table" and tostring(item.user.login or ""))
		or ""
	local actor = actor_from_login(actor_login)
	local date = tostring(item.created_at or item.submitted_at or "")

	if event == "commented" then
		return { kind = "comment", actor = actor, date = date, content_raw = body_text(item.body) }
	elseif event == "reviewed" then
		local state_label = tostring(item.state or ""):lower()
		local kind = state_label == "approved" and "approval"
			or state_label == "changes_requested" and "changes_requested"
			or "review"
		local body = body_text(item.body)
		return {
			kind = kind,
			actor = actor,
			date = date,
			content_raw = body ~= "" and body or nil,
		}
	elseif event == "closed" or event == "merged" or event == "reopened" then
		return { kind = "update", actor = actor, date = date, content_raw = event }
	elseif event == "head_ref_force_pushed" then
		return { kind = "update", actor = actor, date = date, content_raw = "force pushed" }
	elseif event == "committed" then
		local author = type(item.author) == "table" and item.author or {}
		local author_name = tostring(author.name or "")
		return {
			kind = "committed",
			actor = actor_from_login(author_name),
			date = tostring(author.date or date),
			content_raw = "1 commit",
		}
	elseif event == "base_ref_force_pushed" then
		return { kind = "update", actor = actor, date = date, content_raw = "base branch force pushed" }
	elseif event == "labeled" or event == "unlabeled" then
		local label = type(item.label) == "table" and tostring(item.label.name or "") or ""
		if label == "" then
			return nil
		end
		local verb = event == "labeled" and "added label" or "removed label"
		return { kind = "update", actor = actor, date = date, content_raw = verb .. ": " .. label }
	elseif event == "assigned" or event == "unassigned" then
		local assignee = type(item.assignee) == "table" and tostring(item.assignee.login or "") or ""
		if assignee == "" then
			return nil
		end
		local verb = event == "assigned" and "assigned" or "unassigned"
		return { kind = "update", actor = actor, date = date, content_raw = verb .. " " .. assignee }
	elseif event == "review_requested" then
		local reviewer = type(item.requested_reviewer) == "table" and tostring(item.requested_reviewer.login or "")
			or ""
		return {
			kind = "update",
			actor = actor,
			date = date,
			content_raw = reviewer ~= "" and ("requested review from " .. reviewer) or "requested review",
		}
	elseif event == "ready_for_review" then
		return { kind = "update", actor = actor, date = date, content_raw = "marked as ready for review" }
	elseif event == "convert_to_draft" then
		return { kind = "update", actor = actor, date = date, content_raw = "marked as draft" }
	end
	return nil
end

---@param raw table
---@return PullsComment
local function normalize_comment(raw)
	local user = type(raw.user) == "table" and raw.user or (type(raw.actor) == "table" and raw.actor or {})
	local reactions = nil
	if type(raw.reactions) == "table" then
		reactions = {
			["+1"] = tonumber(raw.reactions["+1"]) or 0,
			["-1"] = tonumber(raw.reactions["-1"]) or 0,
			laugh = tonumber(raw.reactions.laugh) or 0,
			hooray = tonumber(raw.reactions.hooray) or 0,
			confused = tonumber(raw.reactions.confused) or 0,
			heart = tonumber(raw.reactions.heart) or 0,
			rocket = tonumber(raw.reactions.rocket) or 0,
			eyes = tonumber(raw.reactions.eyes) or 0,
		}
	end
	return {
		id = raw.id,
		parent_id = nil,
		author = {
			name = tostring(user.login or ""),
			nickname = tostring(user.login or ""),
			id = tostring(user.id or ""),
		},
		content_raw = tostring(raw.body or ""),
		created_on = tostring(raw.created_at or ""),
		deleted = false,
		inline = nil,
		url = nil,
		html_url = tostring(raw.html_url or ""),
		reactions = reactions,
	}
end

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
					table.insert(conversation.comments, normalize_comment(item))
				else
					local entry = normalize_event(item)
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
		end
	)
end

return M
