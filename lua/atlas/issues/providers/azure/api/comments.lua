-- https://learn.microsoft.com/en-us/rest/api/azure/devops/wit/comments/?view=azure-devops-rest-7.1

local M = {}

local json = require("atlas.core.json")
local requests = require("atlas.core.requests")
local mapper = require("atlas.issues.providers.azure.api.mapper")
local markdown = require("atlas.issues.providers.azure.markdown")
local service = require("atlas.pulls.providers.azure.api.service")
local emojis = require("atlas.ui.shared.emojis")

M.reaction_options = {
	{ key = "like", emoji = emojis.glyph("+1"), label = "Like" },
	{ key = "dislike", emoji = emojis.glyph("-1"), label = "Dislike" },
	{ key = "heart", emoji = emojis.glyph("heart"), label = "Heart" },
	{ key = "hooray", emoji = emojis.glyph("hooray"), label = "Hooray" },
	{ key = "smile", emoji = emojis.glyph("laugh"), label = "Smile" },
	{ key = "confused", emoji = emojis.glyph("confused"), label = "Confused" },
}

---@param issue AzureIssue
---@return string
local function comments_endpoint(issue)
	return string.format("/%s/_apis/wit/workItems/%d/comments", service.url_encode(issue.project), issue.id)
end

---@param raw table
---@return AzureIssueComment
local function to_comment(raw)
	local reactions = {}
	for _, reaction in ipairs(raw.reactions or {}) do
		reactions[reaction.type] = reaction.count
	end
	return {
		id = tostring(raw.id),
		self = raw.url,
		author = mapper.to_user(raw.createdBy),
		body = raw.text or "",
		body_format = (raw.format or "html"):lower(),
		created = raw.createdDate,
		updated = raw.modifiedDate,
		reactions = reactions,
		_raw = raw,
	}
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
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
	local items = {}
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
					service.set_cache(cache_key, items)
					on_done(items, nil)
					return
				end

				local raw = result.comments[index]
				scope.run(function(done)
					return markdown.to_markdown(raw.text or "", raw.format, done)
				end, function(body, format)
					local comment = to_comment(raw)
					comment.body = body
					comment.body_format = format
					table.insert(items, {
						id = "comment:" .. comment.id,
						kind = "comment",
						created_at = comment.created,
						entity = comment,
					})
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
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, text, on_done)
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
			on_done(to_comment(result), nil)
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
		on_done(to_comment(result), nil)
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
---@param item IssueConversationItem
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, item, key, on_done)
	---@cast issue AzureIssue
	local comment = item.entity
	---@cast comment IssueComment
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

return M
