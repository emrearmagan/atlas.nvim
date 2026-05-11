local M = {}

local cli = require("atlas.issues.providers.github.api.cli")
local normalizer = require("atlas.issues.providers.github.api.normalizer")
local logger = require("atlas.core.logger")

---@class GHIssueTimelineEntry
---@field event string
---@field actor IssueUser|nil
---@field date string
---@field label_name string|nil
---@field label_color string|nil
---@field assignee_login string|nil
---@field milestone_title string|nil
---@field rename_from string|nil
---@field rename_to string|nil
---@field source_url string|nil
---@field source_title string|nil
---@field commit_id string|nil
---@field commit_url string|nil
---@field comment_body string|nil
---@field comment_url string|nil

---@class GHIssueConversationTimeline
---@field comments IssueComment[]
---@field events GHIssueTimelineEntry[]

---@param value any
---@return any
local function nilify(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	return value
end

---@param value any
---@return string|nil
local function safe_str(value)
	value = nilify(value)
	if value == nil then
		return nil
	end
	return tostring(value)
end

---@param raw table
---@return GHIssueTimelineEntry|nil
local function normalize_event(raw)
	raw = nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local event = safe_str(raw.event) or ""
	if event == "" then
		return nil
	end

	local actor = normalizer.normalize_user(raw.actor) or normalizer.normalize_user(raw.user)
	local date = safe_str(raw.created_at) or ""

	---@type GHIssueTimelineEntry
	local entry = {
		event = event,
		actor = actor,
		date = date,
	}

	if event == "commented" then
		entry.comment_body = safe_str(raw.body) or ""
		entry.comment_url = safe_str(raw.html_url) or ""
	elseif event == "labeled" or event == "unlabeled" then
		local label = nilify(raw.label)
		if type(label) == "table" then
			entry.label_name = safe_str(label.name) or ""
			entry.label_color = safe_str(label.color) or ""
		end
	elseif event == "assigned" or event == "unassigned" then
		local assignee = nilify(raw.assignee)
		if type(assignee) == "table" then
			entry.assignee_login = safe_str(assignee.login) or ""
		end
	elseif event == "milestoned" or event == "demilestoned" then
		local milestone = nilify(raw.milestone)
		if type(milestone) == "table" then
			entry.milestone_title = safe_str(milestone.title) or ""
		end
	elseif event == "renamed" then
		local rename = nilify(raw.rename)
		if type(rename) == "table" then
			entry.rename_from = safe_str(rename.from) or ""
			entry.rename_to = safe_str(rename.to) or ""
		end
	elseif event == "cross-referenced" then
		local source = nilify(raw.source)
		source = type(source) == "table" and source or {}
		local issue = nilify(source.issue)
		issue = type(issue) == "table" and issue or {}
		entry.source_url = safe_str(issue.html_url) or ""
		entry.source_title = safe_str(issue.title) or ""
	elseif event == "referenced" or event == "closed" then
		local commit_id = safe_str(raw.commit_id)
		entry.commit_id = (commit_id and commit_id ~= "") and commit_id:sub(1, 8) or nil
		entry.commit_url = safe_str(raw.commit_url)
	end

	return entry
end

---@param raw table
---@return IssueComment|nil
local function normalize_timeline_comment(raw)
	local comment = {}
	for key, value in pairs(raw) do
		comment[key] = value
	end
	if nilify(comment.user) == nil then
		comment.user = nilify(raw.actor)
	end
	return normalizer.normalize_comment(comment)
end

---@param key string
---@param on_done fun(entries: GHIssueTimelineEntry[]|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.list(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("github_issues:timeline:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch issue timeline", { slug = slug, number = number })
	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/issues/%d/timeline", slug, number) },
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local entries = {}
			for _, raw in ipairs(type(result) == "table" and result or {}) do
				local entry = normalize_event(raw)
				if entry then
					table.insert(entries, entry)
				end
			end
			cli.set_mem(cache_key, entries)
			on_done(entries, nil)
		end
	)
end

---@param key string
---@param on_done fun(result: GHIssueConversationTimeline|nil, err: string|nil)
---@param opts { force_load?: boolean }|nil
---@return { cancel: fun() }|nil
function M.list_conversation(key, on_done, opts)
	opts = opts or {}
	local slug, number = normalizer.parse_key(key)
	if slug == "" or number == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("github_issues:conversation:%s#%d", slug, number)
	if not opts.force_load then
		local cached, ok = cli.get_mem(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	logger.loginfo("GitHub fetch issue conversation timeline", { slug = slug, number = number })
	return cli.gh(
		{ "api", "--paginate", string.format("repos/%s/issues/%d/timeline", slug, number) },
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end

			---@type GHIssueConversationTimeline
			local conversation = { comments = {}, events = {} }
			for _, raw in ipairs(type(result) == "table" and result or {}) do
				local raw_event = type(raw) == "table" and safe_str(raw.event) or ""
				if raw_event == "commented" then
					local comment = normalize_timeline_comment(raw)
					if comment then
						table.insert(conversation.comments, comment)
					end
				else
					local entry = normalize_event(raw)
					if entry then
						table.insert(conversation.events, entry)
					end
				end
			end

			cli.set_mem(cache_key, conversation)
			on_done(conversation, nil)
		end
	)
end

return M
