local M = {}

local cli = require("atlas.providers.github.client")
local mapper = require("atlas.providers.github.mapper")
local reactions = require("atlas.providers.github.reactions")
local json = require("atlas.core.json")

---@class GitHubDiscussionCategory
---@field id string
---@field name string
---@field emoji string
---@field answerable boolean

---@class GitHubDiscussion
---@field number integer
---@field title string
---@field url string
---@field author string|nil
---@field category GitHubDiscussionCategory
---@field labels { name: string, color: string }[]
---@field comments integer
---@field upvotes integer
---@field answered boolean
---@field closed boolean
---@field pinned boolean
---@field created_at string

---@class GitHubDiscussionComment
---@field id string
---@field author string|nil
---@field author_roles string[]|nil
---@field body string
---@field created_at string
---@field upvotes integer
---@field upvoted boolean
---@field answer boolean
---@field deleted boolean
---@field reactions AtlasReaction[]
---@field replies GitHubDiscussionComment[]

---@class GitHubDiscussionDetails : GitHubDiscussion
---@field description GitHubDiscussionComment
---@field subscribed boolean
---@field thread GitHubDiscussionComment[]

---@class GitHubDiscussionPage
---@field items GitHubDiscussion[]
---@field categories GitHubDiscussionCategory[]
---@field next_cursor string|nil

local DISCUSSIONS_QUERY = [[
query($owner: String!, $repo: String!, $search: String!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    hasDiscussionsEnabled
    discussionCategories(first: 25) { nodes { id name emoji isAnswerable } }
    pinnedDiscussions(first: 10) { nodes { discussion { number } } }
  }
  search(type: DISCUSSION, query: $search, first: 50, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Discussion {
        number title url createdAt closed isAnswered upvoteCount
        author { login }
        category { id name emoji isAnswerable }
        labels(first: 10) { nodes { name color } }
        comments { totalCount }
      }
    }
  }
}
]]

local THREAD_QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    discussion(number: $number) {
      id number title url body createdAt closed isAnswered upvoteCount viewerHasUpvoted viewerSubscription
      authorAssociation author { __typename login }
      category { id name emoji isAnswerable }
      labels(first: 10) { nodes { name color } }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
      comments(first: 100) {
        totalCount
        nodes {
          id body createdAt deletedAt isAnswer upvoteCount viewerHasUpvoted
          authorAssociation author { __typename login }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          replies(first: 100) {
            nodes {
              id body createdAt upvoteCount viewerHasUpvoted
              authorAssociation author { __typename login }
              reactionGroups { content viewerHasReacted reactors { totalCount } }
            }
          }
        }
      }
    }
  }
}
]]

---@param raw table
---@return GitHubDiscussionCategory
local function to_category(raw)
	return {
		id = json.safe_str(raw.id) or "",
		name = json.safe_str(raw.name) or "",
		emoji = (json.safe_str(raw.emoji) or ""):gsub(":", ""),
		answerable = raw.isAnswerable == true,
	}
end

---@param raw table
---@return GitHubDiscussion
local function to_discussion(raw)
	local labels = {}
	for _, label in ipairs(json.safe_table(json.safe_table(raw.labels).nodes)) do
		table.insert(labels, { name = json.safe_str(label.name) or "", color = json.safe_str(label.color) or "" })
	end

	return {
		number = tonumber(raw.number) or 0,
		title = json.safe_str(raw.title) or "",
		url = json.safe_str(raw.url) or "",
		author = json.safe_str(json.safe_table(raw.author).login),
		category = to_category(json.safe_table(raw.category)),
		labels = labels,
		comments = tonumber(json.safe_table(raw.comments).totalCount) or 0,
		upvotes = tonumber(raw.upvoteCount) or 0,
		answered = raw.isAnswered == true,
		closed = raw.closed == true,
		pinned = false,
		created_at = json.safe_str(raw.createdAt) or "",
	}
end

---@param raw table
---@param author_login string|nil
---@return GitHubDiscussionComment
local function to_comment(raw, author_login)
	local replies = {}
	for _, reply in ipairs(json.safe_table(json.safe_table(raw.replies).nodes)) do
		table.insert(replies, to_comment(reply, author_login))
	end

	return {
		id = json.safe_str(raw.id) or "",
		author = json.safe_str(json.safe_table(raw.author).login),
		author_roles = mapper.author_roles(raw, author_login),
		body = json.safe_str(raw.body) or "",
		created_at = json.safe_str(raw.createdAt) or "",
		upvotes = tonumber(raw.upvoteCount) or 0,
		upvoted = raw.viewerHasUpvoted == true,
		answer = raw.isAnswer == true,
		deleted = json.safe_str(raw.deletedAt) ~= nil,
		reactions = mapper.graphql_reactions(raw.reactionGroups),
		replies = replies,
	}
end

---@param repo AtlasRepository
---@param opts { query: string, cursor?: string } `query` is a GitHub discussion search, e.g. `repo:owner/name is:open`
---@param on_done fun(page: GitHubDiscussionPage|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(repo, opts, on_done)
	local owner, name = repo.full_name:match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, "Missing repository info")
		return nil
	end

	local args = {
		"api",
		"graphql",
		"-f",
		"query=" .. DISCUSSIONS_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. name,
		"-f",
		"search=" .. opts.query,
	}
	if opts.cursor then
		vim.list_extend(args, { "-f", "endCursor=" .. opts.cursor })
	end

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local data = json.safe_table(result and result.data)
		local repository = json.nilify(data.repository)
		if not repository then
			on_done(nil, "Repository not found")
			return
		end

		if repository.hasDiscussionsEnabled ~= true then
			on_done(nil, "Discussions are disabled for this repository")
			return
		end

		local pinned = {}
		for _, node in ipairs(json.safe_table(json.safe_table(repository.pinnedDiscussions).nodes)) do
			local number = tonumber(json.safe_table(node.discussion).number)
			if number then
				pinned[number] = true
			end
		end

		local search = json.safe_table(data.search)
		local page_info = json.safe_table(search.pageInfo)
		local items = {}
		for _, raw in ipairs(json.safe_table(search.nodes)) do
			local item = to_discussion(raw)
			item.pinned = pinned[item.number] == true
			table.insert(items, item)
		end

		local categories = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(repository.discussionCategories).nodes)) do
			table.insert(categories, to_category(raw))
		end

		on_done({
			items = items,
			categories = categories,
			next_cursor = page_info.hasNextPage == true and json.safe_str(page_info.endCursor) or nil,
		}, nil)
	end, { action = "Fetch discussions", repo = repo.full_name })
end

---@param repo AtlasRepository
---@param number integer
---@param on_done fun(discussion: GitHubDiscussionDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_discussion(repo, number, on_done)
	local owner, name = repo.full_name:match("^([^/]+)/([^/]+)$")
	if not owner then
		on_done(nil, "Missing repository info")
		return nil
	end

	local args = {
		"api",
		"graphql",
		"-f",
		"query=" .. THREAD_QUERY,
		"-f",
		"owner=" .. owner,
		"-f",
		"repo=" .. name,
		"-F",
		"number=" .. number,
	}

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local repository = json.safe_table(json.safe_table(result and result.data).repository)
		local discussion = json.nilify(repository.discussion)
		if not discussion then
			on_done(nil, "Discussion not found")
			return
		end

		local details = to_discussion(discussion)
		---@cast details GitHubDiscussionDetails
		details.description = to_comment(discussion, details.author)
		details.subscribed = discussion.viewerSubscription == "SUBSCRIBED"
		details.thread = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(discussion.comments).nodes)) do
			table.insert(details.thread, to_comment(raw, details.author))
		end

		on_done(details, nil)
	end, { action = "Fetch discussion", repo = repo.full_name })
end

---@param discussion GitHubDiscussionDetails
---@param body string
---@param root GitHubDiscussionComment|nil Top-level comment to reply to
---@param on_done fun(comment: GitHubDiscussionComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(discussion, body, root, on_done)
	local query = [[
mutation($discussionId: ID!, $body: String!, $replyToId: ID) {
  addDiscussionComment(input: { discussionId: $discussionId, body: $body, replyToId: $replyToId }) {
    comment {
      id body createdAt isAnswer upvoteCount viewerHasUpvoted
      authorAssociation author { __typename login }
      reactionGroups { content viewerHasReacted reactors { totalCount } }
    }
  }
}
]]
	local args = {
		"api",
		"graphql",
		"-f",
		"query=" .. query,
		"-f",
		"discussionId=" .. discussion.description.id,
		"-f",
		"body=" .. body,
	}
	if root then
		vim.list_extend(args, { "-f", "replyToId=" .. root.id })
	end

	return cli.gh(args, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local payload = json.safe_table(json.safe_table(result and result.data).addDiscussionComment)
		local comment = json.nilify(payload.comment)
		if not comment then
			on_done(nil, "Comment was not created")
			return
		end

		on_done(to_comment(comment, discussion.author), nil)
	end, { action = "Add discussion comment", number = discussion.number })
end

---@param discussion GitHubDiscussionDetails
---@param comment GitHubDiscussionComment
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(discussion, comment, body, on_done)
	local query =
		"mutation($id: ID!, $body: String!) { updateDiscussionComment(input: { commentId: $id, body: $body }) { clientMutationId } }"
	if comment == discussion.description then
		query =
			"mutation($id: ID!, $body: String!) { updateDiscussion(input: { discussionId: $id, body: $body }) { clientMutationId } }"
	end

	return cli.gh(
		{ "api", "graphql", "-f", "query=" .. query, "-f", "id=" .. comment.id, "-f", "body=" .. body },
		function(_, err)
			on_done(err == nil, err)
		end,
		{ action = "Edit discussion comment", id = comment.id }
	)
end

---@param comment GitHubDiscussionComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(comment, on_done)
	local query = "mutation($id: ID!) { deleteDiscussionComment(input: { id: $id }) { clientMutationId } }"
	return cli.gh({ "api", "graphql", "-f", "query=" .. query, "-f", "id=" .. comment.id }, function(_, err)
		on_done(err == nil, err)
	end, { action = "Delete discussion comment", id = comment.id })
end

---@param comment GitHubDiscussionComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.toggle_answer(comment, on_done)
	local query = "mutation($id: ID!) { markDiscussionCommentAsAnswer(input: { id: $id }) { clientMutationId } }"
	if comment.answer then
		query = "mutation($id: ID!) { unmarkDiscussionCommentAsAnswer(input: { id: $id }) { clientMutationId } }"
	end

	return cli.gh({ "api", "graphql", "-f", "query=" .. query, "-f", "id=" .. comment.id }, function(_, err)
		on_done(err == nil, err)
	end, { action = comment.answer and "Unmark answer" or "Mark answer", id = comment.id })
end

---@param subject GitHubDiscussionComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.toggle_upvote(subject, on_done)
	local query = "mutation($id: ID!) { addUpvote(input: { subjectId: $id }) { clientMutationId } }"
	if subject.upvoted then
		query = "mutation($id: ID!) { removeUpvote(input: { subjectId: $id }) { clientMutationId } }"
	end

	return cli.gh({ "api", "graphql", "-f", "query=" .. query, "-f", "id=" .. subject.id }, function(_, err)
		on_done(err == nil, err)
	end, { action = subject.upvoted and "Remove upvote" or "Add upvote", id = subject.id })
end

---@type AtlasReactionsCapability
M.reactions = {
	options = mapper.reactions,
	add = function(_, subject, key, on_done)
		return reactions.add(subject, key, on_done)
	end,
	remove = function(_, subject, key, on_done)
		return reactions.remove(subject, key, on_done)
	end,
}

return M
