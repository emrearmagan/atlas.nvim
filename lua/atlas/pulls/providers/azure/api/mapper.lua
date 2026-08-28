local M = {}

local json = require("atlas.core.json")
local service = require("atlas.pulls.providers.azure.api.service")

local states = {
	active = "open",
	completed = "merged",
	abandoned = "declined",
}

local decisions = {
	[10] = "approved",
	[5] = "approved",
	[0] = "pending",
	[-5] = "changes_requested",
	[-10] = "changes_requested",
}

local thread_states = {
	fixed = "RESOLVED",
	wontFix = "RESOLVED",
	closed = "RESOLVED",
	byDesign = "RESOLVED",
}

local activity_actors = {
	VoteUpdate = "CodeReviewVotedByIdentity",
	RefUpdate = "CodeReviewRefUpdatedByIdentity",
	ReviewersUpdate = "CodeReviewReviewersUpdatedByIdentity",
	IsDraftUpdate = "CodeReviewIsDraftUpdatedByIdentity",
}

local activity_votes = {
	[10] = { kind = "approval", label = "approved" },
	[5] = { kind = "approval", label = "approved with suggestions" },
	[0] = { kind = "unapproval", label = "reset their vote" },
	[-5] = { kind = "changes_requested", label = "is waiting for the author" },
	[-10] = { kind = "changes_requested", label = "rejected" },
}

---@param raw table
---@return PullsAuthor
local function to_author(raw)
	return {
		name = raw.displayName,
		id = raw.id,
		username = raw.uniqueName,
		nickname = raw.displayName,
	}
end

---@param raw_list table[]|nil
---@return PullsReviewer[]|nil
function M.to_reviewers(raw_list)
	if json.nilify(raw_list) == nil then
		return nil
	end
	local reviewers = {}
	for _, raw in ipairs(raw_list) do
		local author = to_author(raw)
		table.insert(reviewers, {
			name = author.name,
			id = author.id,
			username = author.username,
			nickname = author.nickname,
			provider_id = author.id,
			role = "reviewer",
			decision = decisions[raw.vote],
		})
	end
	return reviewers
end

---@param raw table
---@return AzurePullRequest
function M.to_pull_request(raw)
	local repository = raw.repository
	local project = repository.project.name
	local source_repository = json.safe_table(raw.forkSource).repository or repository

	return {
		id = raw.pullRequestId,
		title = raw.title,
		state = raw.status == "active" and raw.isDraft == true and "draft" or states[raw.status],
		merge_status = json.safe_str(raw.mergeStatus),
		author = to_author(raw.createdBy),
		source = {
			branch = raw.sourceRefName:gsub("^refs/heads/", ""),
			commit_hash = json.safe_table(raw.lastMergeSourceCommit).commitId or "",
			https_url = json.safe_str(source_repository.remoteUrl),
			ssh_url = json.safe_str(source_repository.sshUrl),
		},
		destination = {
			branch = raw.targetRefName:gsub("^refs/heads/", ""),
			commit_hash = json.safe_table(raw.lastMergeTargetCommit).commitId or "",
			https_url = json.safe_str(repository.remoteUrl),
			ssh_url = json.safe_str(repository.sshUrl),
		},
		comments_count = 0, -- Could not find it..
		created_on = raw.creationDate,
		updated_on = json.safe_str(raw.closedDate) or raw.creationDate, -- Also could not find it..
		link = {
			html = string.format(
				"%s/%s/_git/%s/pullrequest/%d",
				service.base_url(),
				service.url_encode(project),
				service.url_encode(repository.name),
				raw.pullRequestId
			),
		},
		provider = "azure",
		project_id = repository.project.id,
		workspace = project,
		repo = repository.name,
		repo_full_name = project .. "/" .. repository.name,
		reviewers = M.to_reviewers(raw.reviewers),
	}
end

---@param raw table
---@param raw_labels table[]
---@return PullRequestDetails
function M.to_pull_request_details(raw, raw_labels)
	local labels = {}
	for _, label in ipairs(raw_labels) do
		table.insert(labels, { name = label.name })
	end
	return {
		description = json.safe_str(raw.description) or "",
		labels = labels,
	}
end

---@param raw_list table[]
---@return AzurePullRequest[]
function M.to_pull_requests(raw_list)
	local pulls = {}
	for _, raw in ipairs(raw_list) do
		table.insert(pulls, M.to_pull_request(raw))
	end
	return pulls
end

---@param raw table
---@param thread table
---@return PullsActivityEntry
local function to_activity(raw, thread)
	local properties = {}
	for key, property in pairs(json.safe_table(thread.properties)) do
		properties[key] = property["$value"]
	end
	local event = properties.CodeReviewThreadType
	local identity = json.safe_table(thread.identities)[properties[activity_actors[event]]]
	local actor = to_author(identity or raw.author)
	local kind = "update"
	local label = raw.content
	local prefix = actor.name .. " "
	if label:sub(1, #prefix) == prefix then
		label = label:sub(#prefix + 1)
	end

	if event == "VoteUpdate" then
		local vote = activity_votes[tonumber(properties.CodeReviewVoteResult)]
		kind = vote.kind
		label = vote.label
	elseif event == "RefUpdate" then
		kind = "committed"
		label = "pushed to " .. properties.CodeReviewRefName:gsub("^refs/heads/", "")
	elseif event == "ReviewersUpdate" then
		kind = "review_requested"
	elseif event == "IsDraftUpdate" then
		local draft = properties.CodeReviewIsDraftNowSet == "1"
		kind = draft and "convert_to_draft" or "ready_for_review"
		label = draft and "marked as draft" or "marked as ready for review"
	end

	return {
		kind = kind,
		actor = actor,
		date = raw.publishedDate,
		label = label,
	}
end

---@param raw table
---@param thread table
---@param pr PullRequest
---@return PullsConversationItem|nil
local function to_conversation_item(raw, thread, pr)
	if raw.isDeleted then
		return nil
	end
	local id = thread.id .. ":" .. raw.id
	if raw.commentType == "text" then
		return {
			id = "comment:" .. id,
			kind = "comment",
			created_on = raw.publishedDate,
			entity = {
				id = id,
				parent_id = raw.parentCommentId > 0 and (thread.id .. ":" .. raw.parentCommentId) or nil,
				thread_id = tostring(thread.id),
				author = to_author(raw.author),
				content_raw = raw.content,
				created_on = raw.publishedDate,
				state = thread_states[thread.status],
				html_url = pr.link.html,
			},
		}
	elseif raw.commentType == "system" then
		return {
			id = "activity:" .. id,
			kind = "activity",
			created_on = raw.publishedDate,
			entity = to_activity(raw, thread),
		}
	end
	return nil
end

---@param raw_list table[]
---@param pr PullRequest
---@return PullsConversationItem[]
function M.to_conversation(raw_list, pr)
	local items = {}
	for _, thread in ipairs(raw_list) do
		if not thread.isDeleted and json.nilify(thread.threadContext) == nil then
			for _, raw in ipairs(thread.comments) do
				local item = to_conversation_item(raw, thread, pr)
				if item then
					table.insert(items, item)
				end
			end
		end
	end
	return items
end

return M
