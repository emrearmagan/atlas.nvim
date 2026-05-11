local M = {}

local cli = require("atlas.pulls.providers.github.api.cli")

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
		return { kind = "comment", actor = actor, date = date, content_raw = tostring(item.body or "") }
	elseif event == "reviewed" then
		local state_label = tostring(item.state or ""):lower()
		local kind = state_label == "approved" and "approval"
			or state_label == "changes_requested" and "changes_requested"
			or "update"
		return { kind = kind, actor = actor, date = date }
	elseif event == "closed" or event == "merged" or event == "reopened" then
		return { kind = "update", actor = actor, date = date, content_raw = event }
	elseif event == "head_ref_force_pushed" then
		return { kind = "update", actor = actor, date = date, content_raw = "force pushed" }
	elseif event == "committed" then
		local author = type(item.author) == "table" and item.author or {}
		local author_name = tostring(author.name or "")
		local msg = tostring(item.message or ""):match("([^\n]+)") or ""
		local sha = tostring(item.sha or ""):sub(1, 8)
		return {
			kind = "update",
			actor = actor_from_login(author_name),
			date = tostring(author.date or date),
			content_raw = sha ~= "" and string.format("%s %s", sha, msg) or msg,
		}
	elseif event == "base_ref_force_pushed" then
		return { kind = "update", actor = actor, date = date, content_raw = "base branch force pushed" }
	elseif event == "labeled" then
		local label = type(item.label) == "table" and tostring(item.label.name or "") or ""
		if label == "" then
			return nil
		end
		return { kind = "update", actor = actor, date = date, content_raw = string.format("added label: %s", label) }
	elseif event == "assigned" then
		local assignee = type(item.assignee) == "table" and tostring(item.assignee.login or "") or ""
		if assignee == "" then
			return nil
		end
		return { kind = "update", actor = actor, date = date, content_raw = string.format("assigned %s", assignee) }
	elseif event == "review_requested" then
		local reviewer = type(item.requested_reviewer) == "table"
				and tostring(item.requested_reviewer.login or "")
			or ""
		return {
			kind = "update",
			actor = actor,
			date = date,
			content_raw = reviewer ~= "" and string.format("requested review from %s", reviewer) or "requested review",
		}
	elseif event == "ready_for_review" then
		return { kind = "update", actor = actor, date = date, content_raw = "marked as ready for review" }
	elseif event == "convert_to_draft" then
		return { kind = "update", actor = actor, date = date, content_raw = "marked as draft" }
	end
	return nil
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsActivityEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_activity(pr, opts, on_done)
	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		vim.schedule(function()
			on_done(nil, "Missing repo")
		end)
		return nil
	end

	local cache_key = string.format("github:activity:%s:%s", repo_slug, tostring(pr.id))
	opts = opts or {}

	if not opts.force_refresh then
		local cached, ok = cli.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return cli.gh(
		{ "api", string.format("repos/%s/issues/%s/timeline", repo_slug, tostring(pr.id)) },
		function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Failed to fetch activity")
				return
			end

			local entries = {}
			for _, item in ipairs(result) do
				local entry = normalize_event(item)
				if entry then
					table.insert(entries, entry)
				end
			end

			cli.set_cache(cache_key, entries)
			on_done(entries, nil)
		end
	)
end

return M
