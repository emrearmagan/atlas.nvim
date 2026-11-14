local M = {}

local comments_api = require("atlas.pulls.providers.gitlab.api.comments")

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(conversation: PullsConversation|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(pr, opts, on_done)
	return comments_api.fetch_conversation_comments(pr, opts, function(conversation, err)
		if conversation == nil then
			on_done(nil, err or "Failed to fetch conversation")
			return
		end
		on_done({
			description = conversation.description,
			comments = conversation.comments,
			reviews = {},
			activities = conversation.activities,
		}, nil)
	end)
end

return M
