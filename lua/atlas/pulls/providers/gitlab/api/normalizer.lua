local json = require("atlas.core.json")

local M = {}

---@param raw any
---@return PullsAuthor
local function normalize_author(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return { name = "Unknown", id = "", username = "unknown", nickname = "unknown" }
	end
	local username = json.safe_str(raw.username) or "unknown"
	local name = json.safe_str(raw.name) or username
	return {
		name = name,
		id = tostring(raw.id or ""),
		username = username,
		nickname = username,
	}
end

---@param mr table
---@return "open"|"merged"|"declined"|"draft"
local function normalize_state(mr)
	if mr.draft == true or mr.work_in_progress == true then
		return "draft"
	end
	local s = tostring(mr.state or ""):lower()
	if s == "merged" then
		return "merged"
	end
	if s == "closed" then
		return "declined"
	end
	return "open"
end

---@param raw_path string|nil
---@return string workspace, string repo, string repo_full_name
local function split_path(raw_path)
	local path = tostring(raw_path or "")
	if path == "" then
		return "", "", ""
	end
	local ws, name = path:match("^(.-)/([^/]+)$")
	if ws and name then
		return ws, name, path
	end
	return "", path, path
end

---@param raw table
---@return PullRequest|nil
function M.normalize_mr(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end

	local iid = tonumber(raw.iid)
	if iid == nil then
		return nil
	end

	-- references.full looks like "group/proj!7"
	local refs = json.nilify(raw.references)
	local full_ref = type(refs) == "table" and json.safe_str(refs.full) or nil
	local project_path = ""
	if full_ref then
		project_path = full_ref:match("^(.-)!%d+$") or ""
	end
	if project_path == "" then
		local web = json.safe_str(raw.web_url) or ""
		project_path = web:match("^https?://[^/]+/(.+)/%-/merge_requests/") or ""
	end

	local workspace, repo, repo_full_name = split_path(project_path)

	local source_branch = json.safe_str(raw.source_branch) or ""
	local target_branch = json.safe_str(raw.target_branch) or ""
	local sha = json.nilify(raw.sha)

	---@type PullRequest
	return {
		id = iid,
		title = json.safe_str(raw.title) or "",
		description = json.safe_str(raw.description) or "",
		state = normalize_state(raw),
		author = normalize_author(raw.author),
		source = { branch = source_branch, commit_hash = "" },
		destination = { branch = target_branch, commit_hash = "" },
		comments_count = tonumber(raw.user_notes_count) or 0,
		tasks_count = 0,
		created_on = json.safe_str(raw.created_at) or "",
		updated_on = json.safe_str(raw.updated_at) or "",
		link = { html = json.safe_str(raw.web_url) or "" },
		provider = "gitlab",
		workspace = workspace,
		repo = repo,
		repo_full_name = repo_full_name,
		is_subscribed = type(raw.subscribed) == "boolean" and raw.subscribed or nil,
		_raw = {
			iid = iid,
			project_id = tonumber(raw.project_id),
			project_path = project_path,
			merge_status = json.safe_str(raw.merge_status),
			detailed_merge_status = json.safe_str(raw.detailed_merge_status),
			blocking_discussions_resolved = json.nilify(raw.blocking_discussions_resolved),
			has_conflicts = raw.has_conflicts == true,
			draft = raw.draft == true or raw.work_in_progress == true,
			labels = json.safe_table(raw.labels),
			assignees = json.safe_table(raw.assignees),
			reviewers = json.safe_table(raw.reviewers),
			milestone = json.nilify(raw.milestone),
			merged_at = json.safe_str(raw.merged_at),
			closed_at = json.safe_str(raw.closed_at),
			sha = type(sha) == "string" and sha or nil,
			pipeline = json.nilify(raw.head_pipeline) or json.nilify(raw.pipeline),
		},
	}
end

---@param raw_list table[]|nil
---@return PullsGroup[] groups grouped by repo_full_name
function M.normalize_mrs_to_groups(raw_list)
	local by_repo = {}
	local order = {}
	for _, raw in ipairs(raw_list or {}) do
		local pr = M.normalize_mr(raw)
		if pr ~= nil then
			local key = pr.repo_full_name ~= "" and pr.repo_full_name or "unknown"
			if not by_repo[key] then
				by_repo[key] = {
					repo = {
						id = key,
						name = pr.repo,
						owner = pr.workspace,
						repo_name = pr.repo,
						html_url = nil,
					},
					prs = {},
				}
				table.insert(order, key)
			end
			table.insert(by_repo[key].prs, pr)
		end
	end

	local groups = {}
	for _, key in ipairs(order) do
		table.insert(groups, by_repo[key])
	end
	return groups
end

---@param raw table|nil
---@return PullsUser|nil
function M.normalize_user(raw)
	raw = json.nilify(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local username = json.safe_str(raw.username) or ""
	if username == "" then
		return nil
	end
	return {
		name = json.safe_str(raw.name) or username,
		id = tostring(raw.id or ""),
		username = username,
	}
end

return M
