local M = {}

local gitlab_reactions = require("atlas.providers.gitlab.reactions")
local service = require("atlas.providers.gitlab.client")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")
local json = require("atlas.core.json")

local GQL_DISCUSSIONS = [[
	query ($fullPath: ID!, $iid: String!) {
		currentUser { username }
		project(fullPath: $fullPath) {
			issue(iid: $iid) {
				id
				webUrl
				description
				createdAt
				author { username name }
				discussions {
					nodes {
						id
						notes {
							nodes {
								id
								body
								system
								createdAt
								maxAccessLevelOfAuthor
								authorIsContributor
								author { username name bot }
								awardEmoji { nodes { name user { name username } } }
							}
						}
					}
				}
			}
			workItems(iids: [$iid], first: 1) {
				nodes { features { awardEmoji { awardEmoji { nodes { name user { name username } } } } } }
			}
		}
	}
]]

local CREATE_NOTE_MUTATION = [[
mutation($noteableId:NoteableID!,$body:String!,$discussionId:DiscussionID){
  createNote(input:{noteableId:$noteableId,body:$body,discussionId:$discussionId}){
    errors
    note{id body createdAt maxAccessLevelOfAuthor authorIsContributor author{username name bot} discussion{id notes(first:1){nodes{id}}}}
  }
}
]]

local UPDATE_NOTE_MUTATION = [[
mutation($id:NoteID!,$body:String!){
  updateNote(input:{id:$id,body:$body}){
    errors
    note{id body createdAt maxAccessLevelOfAuthor authorIsContributor author{username name bot} discussion{id notes(first:1){nodes{id}}}}
  }
}
]]

local DESTROY_NOTE_MUTATION = [[
mutation($id:NoteID!){
  destroyNote(input:{id:$id}){errors}
}
]]

---@param issue Issue
---@return string
local function discussions_cache_key(issue)
	return "gitlab:discussions:" .. tostring(issue.key)
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(result: { description: IssueComment|nil, discussions: table[], viewer: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_discussions(issue, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = discussions_cache_key(issue)
	if opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(GQL_DISCUSSIONS, { fullPath = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.safe_table(data).project
		local raw_issue = json.safe_table(project).issue
		local discussions = json.safe_table(raw_issue).discussions
		local work_items = json.safe_table(json.safe_table(project).workItems).nodes
		local viewer = json.safe_str(json.safe_table(json.safe_table(data).currentUser).username)
		local result = {
			description = normalizer.to_description(
				raw_issue,
				json.safe_table(work_items)[1],
				viewer,
				issue.reporter and issue.reporter.username
			),
			discussions = json.safe_table(json.safe_table(discussions).nodes),
			viewer = viewer,
		}
		service.set_memory_cache(cache_key, result)
		on_done(result, nil)
	end, {
		action = "Fetch discussions (GQL)",
		path = path,
		iid = iid,
	})
end

---@param discussions table[]
---@param viewer string|nil
---@param author_username string|nil
---@return IssueComment[] comments, IssueActivityEntry[] activities
local function map_discussions(discussions, viewer, author_username)
	local comments, activities = {}, {}
	for _, discussion_value in ipairs(discussions) do
		local discussion = json.safe_table(discussion_value)
		for _, raw in ipairs(json.safe_table(json.safe_table(discussion.notes).nodes)) do
			if raw.system == true then
				local entry = normalizer.to_activity_from_note(raw)
				if entry then
					table.insert(activities, entry)
				end
			else
				local comment = normalizer.to_comment(raw, discussion, viewer, author_username)
				if comment then
					table.insert(comments, comment)
				end
			end
		end
	end
	return comments, activities
end

---@param issue Issue
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(conversation: IssueConversation|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation(issue, opts, on_done)
	return fetch_discussions(issue, opts, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		local comments, activities =
			map_discussions(result.discussions, result.viewer, issue.reporter and issue.reporter.username)
		on_done({ description = result.description, comments = comments, activities = activities }, nil)
	end)
end

---@param issue Issue
---@param query string
---@param variables table
---@param mutation string
---@param ctx table
---@param on_done fun(note: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function mutate(issue, query, variables, mutation, ctx, on_done)
	return service.graphql(query, variables, function(data, err)
		local payload = json.safe_table(json.safe_table(data)[mutation])
		local errors = json.safe_table(payload.errors)
		if err or #errors > 0 then
			on_done(nil, err or tostring(errors[1]))
			return
		end
		service.delete_memory_cache(discussions_cache_key(issue))
		on_done(payload.note, nil)
	end, vim.tbl_extend("force", { key = issue.key }, ctx))
end

---@param issue Issue
---@param body string
---@param opts { parent?: IssueComment }|nil
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(issue, body, opts, on_done)
	---@cast issue GitLabIssue
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end
	local parent = opts and opts.parent
	local variables = { noteableId = issue.node_id, body = body, discussionId = parent and parent.thread_id }
	local ctx = { action = parent and "Reply in discussion" or "Add discussion" }
	return mutate(issue, CREATE_NOTE_MUTATION, variables, "createNote", ctx, function(note, err)
		local comment = note
			and normalizer.to_comment(note, note.discussion, nil, issue.reporter and issue.reporter.username)
		if not comment then
			on_done(nil, err or "GitLab did not return the created comment")
			return
		end
		on_done(comment, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param body string
---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(issue, comment, body, on_done)
	if vim.trim(body) == "" then
		on_done(nil, "Comment cannot be empty")
		return nil
	end
	local variables = { id = comment.id, body = body }
	local ctx = { action = "Edit note", note_id = comment.id }
	return mutate(issue, UPDATE_NOTE_MUTATION, variables, "updateNote", ctx, function(note, err)
		local updated = note
			and normalizer.to_comment(note, note.discussion, nil, issue.reporter and issue.reporter.username)
		if not updated then
			on_done(nil, err or "GitLab did not return the updated comment")
			return
		end
		updated.reactions = comment.reactions
		on_done(updated, nil)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(issue, comment, on_done)
	local ctx = { action = "Delete note", note_id = comment.id }
	return mutate(issue, DESTROY_NOTE_MUTATION, { id = comment.id }, "destroyNote", ctx, function(_, err)
		on_done(err == nil, err)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param name string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_reaction(issue, comment, name, on_done)
	return gitlab_reactions.add(comment, name, function(ok, err)
		if ok then
			service.delete_memory_cache(discussions_cache_key(issue))
		end
		on_done(ok, err)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param name string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.remove_reaction(issue, comment, name, on_done)
	return gitlab_reactions.remove(comment, name, function(ok, err)
		if ok then
			service.delete_memory_cache(discussions_cache_key(issue))
		end
		on_done(ok, err)
	end)
end

return M
