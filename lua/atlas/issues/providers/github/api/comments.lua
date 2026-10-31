local M = {}

local cache = require("atlas.issues.providers.github.api.cache")
local cli = require("atlas.providers.github.client")
local github_reactions = require("atlas.providers.github.reactions")
local json = require("atlas.core.json")
local normalizer = require("atlas.issues.providers.github.api.mapper")

local ADD_COMMENT_MUTATION = [[
mutation($id:ID!,$body:String!){
  addComment(input:{subjectId:$id,body:$body}){
    commentEdge{node{id url body createdAt authorAssociation author{__typename login ...on User{name databaseId} ...on Bot{databaseId}}}}
  }
}
]]

local UPDATE_COMMENT_MUTATION = [[
mutation($id:ID!,$body:String!){
  updateIssueComment(input:{id:$id,body:$body}){
    issueComment{id url body createdAt authorAssociation author{__typename login ...on User{name databaseId} ...on Bot{databaseId}}}
  }
}
]]

local DELETE_COMMENT_MUTATION = [[
mutation($id:ID!){
  deleteIssueComment(input:{id:$id}){clientMutationId}
}
]]

---@param issue Issue
---@param body string
---@param _opts { parent?: IssueComment }|nil
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(issue, body, _opts, on_done)
	---@cast issue GitHubIssue
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"id=" .. tostring(issue.node_id or ""),
		"-f",
		"body=" .. body,
		"-f",
		"query=" .. ADD_COMMENT_MUTATION,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local edge = json.safe_table(json.safe_table(json.safe_table(result.data).addComment).commentEdge)
		local comment = normalizer.to_comment(edge.node, issue.reporter and issue.reporter.username)
		if not comment then
			on_done(nil, "GitHub did not return the created comment")
			return
		end
		cache.invalidate(issue.key)
		on_done(comment, nil)
	end, {
		action = "Add issue comment",
		slug = issue.repo_full_name,
		number = issue.number,
	})
end

---@param issue Issue
---@param comment IssueComment
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit(issue, comment, body, on_done)
	---@cast issue GitHubIssue
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end

	return cli.gh({
		"api",
		"graphql",
		"-f",
		"id=" .. comment.id,
		"-f",
		"body=" .. body,
		"-f",
		"query=" .. UPDATE_COMMENT_MUTATION,
	}, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Empty response")
			return
		end
		local payload = json.safe_table(json.safe_table(result.data).updateIssueComment)
		local updated = normalizer.to_comment(payload.issueComment, issue.reporter and issue.reporter.username)
		if not updated then
			on_done(nil, "GitHub did not return the updated comment")
			return
		end
		cache.invalidate(issue.key)
		updated.reactions = comment.reactions
		on_done(updated, nil)
	end, {
		action = "Edit issue comment",
		slug = issue.repo_full_name,
		comment_id = comment.id,
	})
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete(issue, comment, on_done)
	---@cast issue GitHubIssue
	return cli.gh(
		{ "api", "graphql", "-f", "id=" .. comment.id, "-f", "query=" .. DELETE_COMMENT_MUTATION },
		function(_, err)
			if err then
				on_done(false, err)
				return
			end
			cache.invalidate(issue.key)
			on_done(true, nil)
		end,
		{
			action = "Delete issue comment",
			slug = issue.repo_full_name,
			comment_id = comment.id,
		}
	)
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, key, on_done)
	return github_reactions.add(comment, key, function(ok, err)
		if ok then
			cache.invalidate(issue.key)
		end
		on_done(ok, err)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.remove_reaction(issue, comment, key, on_done)
	return github_reactions.remove(comment, key, function(ok, err)
		if ok then
			cache.invalidate(issue.key)
		end
		on_done(ok, err)
	end)
end

return M
