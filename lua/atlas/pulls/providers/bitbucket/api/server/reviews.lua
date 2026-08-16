local M = {}

local pullrequests = require("atlas.pulls.providers.bitbucket.api.server.pullrequests")

M.has_action = pullrequests.has_action
M.fetch_review_context = pullrequests.fetch_review_context

---@param _pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return nil
function M.fetch_review(_pr, _opts, on_done)
	on_done({
		review = { id = nil, commit_hash = nil, pending = false },
		comments = {},
		tasks = {},
	}, nil)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.approve(pr, _review, body, on_done)
	if vim.trim(body) ~= "" then
		on_done(false, "Bitbucket Server review comments are not supported")
		return nil
	end
	return pullrequests.approve(pr, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes(pr, _review, body, on_done)
	if vim.trim(body) ~= "" then
		on_done(false, "Bitbucket Server review comments are not supported")
		return nil
	end
	return pullrequests.request_changes(pr, function(_, err)
		on_done(err == nil, err)
	end)
end

return M
