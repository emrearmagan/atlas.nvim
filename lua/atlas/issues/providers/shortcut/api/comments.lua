local M = {}

local mapper = require("atlas.issues.providers.shortcut.api.mapper")
local members = require("atlas.issues.providers.shortcut.api.members")
local requests = require("atlas.core.requests")
local service = require("atlas.issues.providers.shortcut.api.service")

---@param story_id integer
---@return string
local function cache_key(story_id)
	return "story:" .. tostring(story_id) .. ":comments"
end

---@param story_id integer
local function invalidate(story_id)
	service.clear_cache("story:" .. tostring(story_id))
	service.clear_cache("search:")
end

---@param text string
---@return string|nil
local function validate(text)
	if vim.trim(text) == "" then
		return "Comment cannot be empty"
	end
	if vim.fn.strchars(text) > 100000 then
		return "Shortcut comments cannot exceed 100,000 characters"
	end
end

---@param raw_comments table[]
---@param users IssueUser[]
---@return IssueComment[]
local function map_comments(raw_comments, users)
	local comments = {}
	for _, raw in ipairs(raw_comments) do
		table.insert(comments, mapper.to_comment(raw, users))
	end
	return comments
end

---@param issue Issue
---@param opts { force_load?: boolean }|nil
---@param on_done fun(comments: IssueComment[]|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.list(issue, opts, on_done)
	---@cast issue ShortcutIssue
	local story_id = issue.id
	opts = opts or {}
	if not opts.force_load then
		local cached, found = service.get_memory_cache(cache_key(story_id))
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = requests.new()
	scope.run(function(done)
		return members.list(done)
	end, function(users, users_err)
		if users_err then
			on_done(nil, users_err)
			return
		end

		local endpoint = string.format("/stories/%d/comments", story_id)
		scope.run(function(done)
			return service.request("GET", endpoint, nil, done, {
				action = "Fetch Shortcut Story comments",
				issue_key = tostring(story_id),
			})
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			---@cast result table[]
			local comments = map_comments(result, users)
			service.set_memory_cache(cache_key(story_id), comments)
			on_done(comments, nil)
		end)
	end)
	return scope
end

---@param issue Issue
---@param text string
---@param parent_id string|number|nil
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return AtlasRequestScope|nil
local function create_comment(issue, text, parent_id, on_done)
	---@cast issue ShortcutIssue
	local story_id = issue.id
	local err = validate(text)
	if err then
		on_done(nil, err)
		return nil
	end

	local scope = requests.new()
	scope.run(function(done)
		return members.get_current(done)
	end, function(user, user_err)
		if user_err then
			on_done(nil, user_err)
			return
		end
		---@cast user IssueUser

		local endpoint = string.format("/stories/%d/comments", story_id)
		scope.run(function(done)
			return service.request(
				"POST",
				endpoint,
				{ text = text, parent_id = parent_id and tonumber(parent_id) or nil },
				done,
				{
					action = "Create Shortcut Story comment",
					issue_key = tostring(story_id),
				}
			)
		end, function(result, request_err)
			if request_err then
				on_done(nil, request_err)
				return
			end
			---@cast result table
			invalidate(story_id)
			on_done(mapper.to_comment(result, { user }), nil)
		end)
	end)
	return scope
end

---@param issue Issue
---@param text string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.add_comment(issue, text, on_done)
	return create_comment(issue, text, nil, on_done)
end

---@param issue Issue
---@param parent IssueComment
---@param text string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.reply_comment(issue, parent, text, on_done)
	return create_comment(issue, text, parent.id, on_done)
end

---@param issue Issue
---@param comment IssueComment
---@param text string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, text, on_done)
	---@cast issue ShortcutIssue
	local story_id = issue.id
	local err = validate(text)
	if err then
		on_done(nil, err)
		return nil
	end

	local endpoint = string.format("/stories/%d/comments/%s", story_id, tostring(comment.id))
	return service.request("PUT", endpoint, { text = text }, function(result, request_err)
		if request_err then
			on_done(nil, request_err)
			return
		end
		---@cast result table
		invalidate(story_id)
		local updated = mapper.to_comment(result)
		updated.author = updated.author or comment.author
		on_done(updated, nil)
	end, {
		action = "Update Shortcut Story comment",
		issue_key = tostring(story_id),
	})
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	---@cast issue ShortcutIssue
	local story_id = issue.id
	local endpoint = string.format("/stories/%d/comments/%s", story_id, tostring(comment.id))
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate(story_id)
		on_done(true, nil)
	end, {
		action = "Delete Shortcut Story comment",
		issue_key = tostring(story_id),
	})
end

return M
