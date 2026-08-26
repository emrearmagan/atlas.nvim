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

return M
