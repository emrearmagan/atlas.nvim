-- https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/comments/?view=azure-devops-rest-7.1

local M = {}

local json = require("atlas.core.json")
local requests = require("atlas.core.requests")
local users = require("atlas.providers.azure.users")
local markdown = require("atlas.issues.providers.azure.markdown")
local service = require("atlas.providers.azure.client")

---@type AtlasReactionOption[]
M.reactions = {
	{ name = "thumbsup", key = "like" },
	{ name = "thumbsdown", key = "dislike" },
	{ name = "heart" },
	{ name = "tada", key = "hooray" },
	{ name = "laughing", key = "smile" },
	{ name = "confused" },
}

---@param issue AzureIssue
---@return string
local function comments_endpoint(issue)
	return string.format("/%s/_apis/wit/workItems/%d/comments", service.url_encode(issue.project), issue.id)
end

---@param raw table
---@param issue AzureIssue
---@return AzureIssueComment
local function to_comment(raw, issue)
	local reactions = {}
	for _, reaction in ipairs(json.safe_table(raw.reactions)) do
		local count = tonumber(reaction.count) or 0
		if count > 0 then
			local name = reaction.type
			for _, option in ipairs(M.reactions) do
				if (option.key or option.name) == reaction.type then
					name = option.name
				end
			end
			table.insert(reactions, { name = name, count = count, reacted = reaction.isCurrentUserEngaged == true })
		end
	end
	local author = users.to_user(raw.createdBy)
	local authors = {}
	users.add_mention_name(authors, author)
	local reporter_id = issue.reporter and issue.reporter.id
	return {
		id = tostring(raw.id),
		author = author,
		author_roles = author and author.id and author.id == reporter_id and { "Author" } or nil,
		body = raw.text or "",
		body_display = users.resolve_mentions(raw.text or "", authors),
		body_format = (raw.format or "html"):lower(),
		created_at = raw.createdDate or "",
		reactions = reactions,
	}
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(conversation: IssueConversation|nil, err: string|nil)
---@return AtlasRequestScope|nil
function M.fetch_conversation(issue, opts, on_done)
	---@cast issue AzureIssue
	opts = opts or {}
	local cache_key = "workitem:" .. issue.key .. ":comments"
	if not opts.force_refresh then
		local cached, found = service.get_cache(cache_key)
		if found then
			on_done(cached, nil)
			return nil
		end
	end

	local scope = requests.new()
	local comments = {}
	local function fetch_page(token)
		local query = service.build_query({
			["$top"] = 100,
			["$expand"] = "reactions",
			order = "asc",
			continuationToken = token,
		})
		scope.run(function(done)
			return service.request("GET", comments_endpoint(issue) .. query, nil, done, {
				action = "Fetch work item comments",
				issue_key = issue.key,
			}, "7.1-preview.4")
		end, function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local function convert_comment(index)
				if index > #result.comments then
					local next_token = json.safe_str(result.continuationToken)
					if next_token and next_token ~= "" then
						fetch_page(next_token)
						return
					end
					local authors = {}
					users.add_mention_name(authors, issue.reporter)
					users.add_mention_name(authors, issue.assignee)
					for _, comment in ipairs(comments) do
						users.add_mention_name(authors, comment.author)
					end
					for _, comment in ipairs(comments) do
						comment.body_display = users.resolve_mentions(comment.body, authors)
					end
					local conversation = { comments = comments, activities = {} }
					service.set_cache(cache_key, conversation)
					on_done(conversation, nil)
					return
				end

				local raw = result.comments[index]
				scope.run(function(done)
					return markdown.to_markdown(raw.text or "", raw.format, done)
				end, function(body, format)
					local comment = to_comment(raw, issue)
					comment.body = body
					comment.body_format = format
					table.insert(comments, comment)
					convert_comment(index + 1)
				end)
			end
			convert_comment(1)
		end)
	end
	fetch_page(nil)
	return scope
end

---@param issue Issue
---@param text string
---@param _opts { parent?: IssueComment }|nil
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, text, _opts, on_done)
	---@cast issue AzureIssue
	return service.request(
		"POST",
		comments_endpoint(issue) .. "?format=markdown",
		{ text = text },
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			service.clear_cache()
			on_done(to_comment(result, issue), nil)
		end,
		{ action = "Add work item comment", issue_key = issue.key },
		"7.1-preview.4"
	)
end

---@param issue Issue
---@param comment IssueComment
---@param text string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, text, on_done)
	---@cast issue AzureIssue
	---@cast comment AzureIssueComment
	local query = service.build_query({ format = comment.body_format })
	local endpoint = comments_endpoint(issue) .. "/" .. comment.id .. query
	return service.request("PATCH", endpoint, { text = text }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.clear_cache()
		on_done(to_comment(result, issue), nil)
	end, { action = "Edit work item comment", issue_key = issue.key, comment_id = comment.id }, "7.1-preview.4")
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	---@cast issue AzureIssue
	local endpoint = comments_endpoint(issue) .. "/" .. comment.id
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, { action = "Delete work item comment", issue_key = issue.key, comment_id = comment.id }, "7.1-preview.4")
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, key, on_done)
	---@cast issue AzureIssue
	local endpoint = comments_endpoint(issue) .. "/" .. comment.id .. "/reactions/" .. key
	return service.request("PUT", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, { action = "Add work item comment reaction", issue_key = issue.key, comment_id = comment.id }, "7.1-preview.1")
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.remove_reaction(issue, comment, key, on_done)
	---@cast issue AzureIssue
	local endpoint = comments_endpoint(issue) .. "/" .. comment.id .. "/reactions/" .. key
	return service.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		service.clear_cache()
		on_done(true, nil)
	end, {
		action = "Remove work item comment reaction",
		issue_key = issue.key,
		comment_id = comment.id,
	}, "7.1-preview.1")
end

return M
