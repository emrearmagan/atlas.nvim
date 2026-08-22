local M = {}

local comments_api = require("atlas.pulls.providers.gitlab.api.comments")
local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client").pulls

local REVIEW_METADATA_QUERY = [[
query($path:ID!,$iid:String!,$after:String){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      diffRefs{baseSha startSha headSha}
      reviewers(first:100){
        nodes{id name username mergeRequestInteraction{reviewState}}
      }
      approvedBy(first:100){nodes{id name username}}
      notes(filter:ONLY_ACTIVITY,first:100,after:$after){
        pageInfo{hasNextPage endCursor}
        nodes{
          id
          system
          createdAt
          url
          author{id name username}
          systemNoteMetadata{action}
        }
      }
    }
  }
}
]]

local REVIEWERS_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      reviewers(first:100){
        nodes{id name username mergeRequestInteraction{reviewState}}
      }
      approvedBy(first:100){nodes{id name username}}
    }
  }
}
]]

local HISTORY_STATES = {
	approved = "approved",
	requested_changes = "changes_requested",
	unapproved = "unapproved",
}

---@param pr PullRequest
---@return string project_path, integer|nil iid
local function project_iid(pr)
	return pr.repo_full_name, tonumber(pr.id)
end

---@param path string
---@param iid integer
---@return string
local function metadata_cache_key(path, iid)
	return string.format("gitlab_pulls:review_metadata:%s!%d", path, iid)
end

---@param path string
---@param iid integer
local function bust_review_caches(path, iid)
	service.delete_memory_cache(string.format("gitlab_pulls:comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:general-comments:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:activity:%s!%d", path, iid))
	service.delete_memory_cache(string.format("gitlab_pulls:reviewers:%s!%d", path, iid))
	service.delete_memory_cache(metadata_cache_key(path, iid))
end

---@param pr PullRequest
local function bust_pull_request_cache(pr)
	local path, iid = project_iid(pr)
	if path ~= "" and iid then
		service.delete_memory_cache(string.format("gitlab_pulls:get:%s!%d", path, iid))
	end
end

---@param raw table|nil
---@return PullsAuthor|nil
local function to_author(raw)
	raw = json.safe_table(raw)
	local username = json.safe_str(raw.username) or ""
	local name = json.safe_str(raw.name) or ""
	if username == "" and name == "" then
		return nil
	end
	return {
		id = json.safe_str(raw.id) or "",
		name = name ~= "" and name or username,
		username = username,
		nickname = username ~= "" and username or nil,
	}
end

---@param merge_request table
---@return PullsReviewer[]
local function map_reviewers(merge_request)
	local reviewers = {}
	local by_id = {}
	for _, node in ipairs(json.safe_table(json.safe_table(merge_request.reviewers).nodes)) do
		local author = to_author(node)
		if author then
			local interaction = json.safe_table(node.mergeRequestInteraction)
			local state = (json.safe_str(interaction.reviewState) or ""):lower()
			local reviewer = vim.tbl_extend("force", author, {
				role = "reviewer",
				decision = state == "approved" and "approved"
					or (state == "requested_changes" and "changes_requested")
					or (state == "reviewed" and "reviewed")
					or "pending",
			})
			by_id[author.id] = reviewer
			table.insert(reviewers, reviewer)
		end
	end
	for _, node in ipairs(json.safe_table(json.safe_table(merge_request.approvedBy).nodes)) do
		local author = to_author(node)
		if author then
			local reviewer = by_id[author.id]
			if reviewer then
				reviewer.decision = "approved"
			else
				table.insert(
					reviewers,
					vim.tbl_extend("force", author, {
						decision = "approved",
						role = "participant",
					})
				)
			end
		end
	end
	return reviewers
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: { reviewers: PullsReviewer[], history: PullsReviewHistoryEntry[], diff_refs: table|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_metadata(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = metadata_cache_key(path, iid)
	if not opts.force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local reviewers, history = {}, {}
	local after
	local current
	local cancelled = false

	local function fetch_page()
		current = service.graphql(REVIEW_METADATA_QUERY, {
			path = path,
			iid = tostring(iid),
			after = after,
		}, function(result, err)
			if cancelled then
				return
			end
			if err then
				on_done(nil, err)
				return
			end

			local project = json.nilify(result and result.project)
			local merge_request = project and json.nilify(project.mergeRequest)
			if not merge_request then
				on_done(nil, "GitLab did not return the merge request")
				return
			end

			if after == nil then
				reviewers = map_reviewers(merge_request)
			end

			local notes = json.safe_table(merge_request.notes)
			for _, note in ipairs(json.safe_table(notes.nodes)) do
				local metadata = json.safe_table(note.systemNoteMetadata)
				local state = note.system == true and HISTORY_STATES[json.safe_str(metadata.action) or ""] or nil
				if state then
					table.insert(history, {
						id = json.safe_str(note.id),
						author = to_author(note.author),
						state = state,
						submitted_on = json.safe_str(note.createdAt) or "",
						body = nil,
						commit_hash = nil,
						url = json.safe_str(note.url),
					})
				end
			end

			local page_info = json.safe_table(notes.pageInfo)
			local end_cursor = json.safe_str(page_info.endCursor) or ""
			if page_info.hasNextPage == true and end_cursor ~= "" then
				after = end_cursor
				fetch_page()
				return
			end

			table.sort(history, function(a, b)
				if a.submitted_on == b.submitted_on then
					return tostring(a.id or "") < tostring(b.id or "")
				end
				return a.submitted_on < b.submitted_on
			end)
			local refs = json.safe_table(merge_request.diffRefs)
			local data = {
				reviewers = reviewers,
				history = history,
				diff_refs = {
					base_sha = json.safe_str(refs.baseSha),
					start_sha = json.safe_str(refs.startSha),
					head_sha = json.safe_str(refs.headSha),
				},
			}
			service.set_memory_cache(cache_key, data)
			on_done(data, nil)
		end, {
			action = "Fetch MR review metadata",
			project_path = path,
			iid = iid,
		})
	end

	fetch_page()
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param refs table|nil
---@return boolean
local function complete_diff_refs(refs)
	return type(refs) == "table"
		and tostring(refs.base_sha or "") ~= ""
		and tostring(refs.start_sha or "") ~= ""
		and tostring(refs.head_sha or "") ~= ""
end

---@param comments PullsComment[]
---@param current table|nil
local function mark_outdated(comments, current)
	if not complete_diff_refs(current) then
		return
	end
	for _, comment in ipairs(comments) do
		local refs = (comment._raw or {}).diff_refs
		if
			complete_diff_refs(refs)
			and (
				refs.base_sha ~= current.base_sha
				or refs.start_sha ~= current.start_sha
				or refs.head_sha ~= current.head_sha
			)
		then
			comment.outdated = true
			comment.state = comment.state or "OUTDATED"
		end
	end
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch(pr, opts, on_done)
	local comments_request
	local metadata_request
	local cancelled = false
	local pending = 2
	local review_data
	local metadata = { reviewers = {}, history = {}, diff_refs = nil }
	local review_error, metadata_error

	local function finish()
		if cancelled then
			return
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if review_data == nil or metadata_error then
			on_done(nil, review_error or metadata_error or "Failed to fetch review")
			return
		end
		review_data.reviewers = metadata.reviewers
		review_data.history = metadata.history
		mark_outdated(review_data.comments, metadata.diff_refs)
		if complete_diff_refs(metadata.diff_refs) then
			pr._raw.diff_refs = metadata.diff_refs
		end
		on_done(review_data, nil)
	end

	comments_request = comments_api.fetch(pr, opts, function(result, err)
		if cancelled then
			return
		end
		if not result then
			review_error = err
			finish()
			return
		end
		local comments = {}
		local pending = false
		for _, comment in ipairs(result) do
			pending = pending or comment.state == "PENDING"
			if comment.inline or comment.file then
				table.insert(comments, comment)
			end
		end
		review_data = {
			review = { id = nil, commit_hash = nil, pending = pending },
			comments = comments,
			tasks = {},
		}
		finish()
	end)
	metadata_request = fetch_metadata(pr, opts, function(result, err)
		metadata = result or metadata
		metadata_error = err
		finish()
	end)
	return {
		cancel = function()
			cancelled = true
			if comments_request then
				comments_request.cancel()
			end
			if metadata_request then
				metadata_request.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
function M.fetch_context(pr, _opts, on_done)
	local authors = {}
	local seen = {}
	---@param author PullsAuthor|nil
	local function add(author)
		if not author then
			return
		end
		local key = tostring(author.id or "")
		if key == "" then
			key = tostring(author.username or author.nickname or author.name or "")
		end
		if key == "" or seen[key] then
			return
		end
		seen[key] = true
		table.insert(authors, author)
	end

	add(pr.author)
	for _, list in ipairs({ pr.assignees or {}, pr.reviewers or {} }) do
		for _, user in ipairs(list) do
			add(user)
		end
	end
	on_done({ authors = authors }, nil)
end

---@param pr PullRequest
---@param _review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.discard(pr, _review, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end

	local prefix = string.format("/projects/%s/merge_requests/%d/draft_notes", service.url_encode(path), iid)
	local current
	local cancelled = false
	local function delete_next(drafts, index)
		if cancelled then
			return
		end
		local draft = drafts[index]
		if not draft then
			bust_review_caches(path, iid)
			on_done(true, nil)
			return
		end
		current = service.request("DELETE", prefix .. "/" .. tostring(draft.id), nil, function(_, err)
			if err then
				on_done(false, err)
				return
			end
			delete_next(drafts, index + 1)
		end)
	end

	current = service.fetch_all_pages(prefix .. "?per_page=100", function(drafts, err)
		if err then
			on_done(false, err)
			return
		end
		delete_next(drafts or {}, 1)
	end)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param reviewer_state "reviewed"|"requested_changes"|nil
---@param body string|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.publish(pr, reviewer_state, body, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end

	local payload
	if body and vim.trim(body) ~= "" then
		payload = { note = body }
	end
	if reviewer_state then
		payload = payload or {}
		payload.reviewer_state = reviewer_state
	end

	local endpoint =
		string.format("/projects/%s/merge_requests/%d/draft_notes/bulk_publish", service.url_encode(path), iid)
	return service.request("POST", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_review_caches(path, iid)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function approve_pull_request(pr, on_done)
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(false, "Invalid MR identifier")
		return nil
	end
	local endpoint = string.format("/projects/%s/merge_requests/%d/approve", service.url_encode(path), iid)
	return service.request("POST", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		bust_pull_request_cache(pr)
		on_done(true, nil)
	end)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.submit(pr, _review, body, on_done)
	return M.publish(pr, "reviewed", body, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve(pr, _review, body, on_done)
	local cancelled = false
	local current
	current = M.publish(pr, "reviewed", body, function(ok, err)
		if cancelled then
			return
		end
		if not ok then
			on_done(false, err)
			return
		end
		current = approve_pull_request(pr, on_done)
	end)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.request_changes(pr, _review, body, on_done)
	return M.publish(pr, "requested_changes", body, on_done)
end

---@param pr PullRequest
---@param opts { force_refresh?: boolean }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	opts = opts or {}
	local path, iid = project_iid(pr)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:reviewers:%s!%d", path, iid)
	if opts.force_refresh ~= true then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(REVIEWERS_QUERY, { path = path, iid = tostring(iid) }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.nilify(result and result.project)
		local merge_request = project and json.nilify(project.mergeRequest)
		if not merge_request then
			on_done(nil, "GitLab did not return the merge request")
			return
		end
		local reviewers = map_reviewers(merge_request)
		service.set_memory_cache(cache_key, reviewers)
		on_done(reviewers, nil)
	end, { action = "Fetch MR reviewers", project_path = path, iid = iid })
end

return M
