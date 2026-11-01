local M = {}

local cli = require("atlas.providers.github.client")

---@param mutation string
---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param key string GraphQL `ReactionContent`
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function mutate(mutation, comment, key, on_done)
	local subject_id = tostring(comment.id or "")
	if subject_id == "" then
		on_done(false, "Missing comment id")
		return nil
	end
	local query = string.format(
		"mutation($id:ID!,$content:ReactionContent!){%s(input:{subjectId:$id,content:$content}){clientMutationId}}",
		mutation
	)
	return cli.gh(
		{ "api", "graphql", "-f", "id=" .. subject_id, "-f", "content=" .. key, "-f", "query=" .. query },
		function(_, err)
			on_done(err == nil, err)
		end,
		{
			action = mutation,
			comment_id = subject_id,
			reaction = key,
		}
	)
end

---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add(comment, key, on_done)
	return mutate("addReaction", comment, key, on_done)
end

---@param comment IssueComment|PullsComment|GitHubDiscussionComment
---@param key string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.remove(comment, key, on_done)
	return mutate("removeReaction", comment, key, on_done)
end

return M
