local M = {}

local json = require("atlas.core.json")
local pipelines = require("atlas.pulls.pipelines")
local gitlab_pipelines = require("atlas.pulls.providers.gitlab.api.pipelines")
local service = require("atlas.providers.gitlab.client")

local MERGE_CHECKS_QUERY = [[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      draft
      detailed_merge_status:detailedMergeStatus
      blocking_discussions_resolved:mergeableDiscussionsState
      has_conflicts:conflicts
      head_pipeline:headPipeline{status}
    }
  }
}
]]

---@class GitLabMergeCheckState
---@field draft boolean
---@field detailed_merge_status string|nil
---@field blocking_discussions_resolved boolean|nil
---@field has_conflicts boolean
---@field head_pipeline_status string|nil

---@param state GitLabMergeCheckState
---@return PullsMergeCheck[]
local function parse_merge_checks(state)
	local checks = {}
	local dms = tostring(state.detailed_merge_status or ""):lower()
	local has_conflicts = state.has_conflicts == true

	if state.draft then
		table.insert(checks, {
			key = "draft",
			state = "warning",
			label = "This merge request is still a draft",
			details = { "Draft merge requests cannot be merged." },
		})
	end

	if has_conflicts or dms == "conflict" then
		table.insert(checks, {
			key = "conflicts",
			state = "failed",
			label = "This branch has conflicts that must be resolved",
			details = { "Conflicting files must be resolved before merging." },
		})
	elseif dms == "mergeable" then
		table.insert(checks, {
			key = "conflicts",
			state = "successful",
			label = "No conflicts with target branch",
		})
	end

	if state.blocking_discussions_resolved == false or dms == "discussions_not_resolved" then
		table.insert(checks, {
			key = "discussions",
			state = "failed",
			label = "Unresolved discussions",
			details = { "Resolve all threads before merging." },
		})
	end

	if dms == "merge_request_blocked" then
		table.insert(checks, {
			key = "blocks",
			state = "failed",
			label = "Merge request dependencies must be merged",
		})
	end

	if dms == "requested_changes" then
		table.insert(checks, {
			key = "requested_changes",
			state = "failed",
			label = "Change requests must be approved by the requesting user",
		})
	end

	if dms == "not_approved" then
		table.insert(checks, {
			key = "approvals",
			state = "failed",
			label = "All required approvals must be given",
		})
	end

	if dms == "need_rebase" then
		table.insert(checks, {
			key = "rebase",
			state = "failed",
			label = "Source branch must be rebased onto target",
		})
	end

	if dms == "jira_association_missing" then
		table.insert(checks, {
			key = "jira",
			state = "failed",
			label = "Jira issue must be referenced",
		})
	end

	if dms == "external_status_checks" then
		table.insert(checks, {
			key = "external_checks",
			state = "failed",
			label = "External status checks must pass",
		})
	end

	if dms == "broken_status" then
		table.insert(checks, {
			key = "broken",
			state = "failed",
			label = "Merge status is broken",
		})
	end

	if dms == "preparing" then
		table.insert(checks, {
			key = "preparing",
			state = "inprogress",
			label = "Preparing merge",
		})
	end

	local pipeline_status = state.head_pipeline_status
	if pipeline_status ~= nil and pipeline_status ~= "" then
		local pipeline_check = pipelines.to_merge_check({
			{ state = gitlab_pipelines.to_pipeline_state(pipeline_status) },
		}, "Pipelines")
		if pipeline_check then
			table.insert(checks, pipeline_check)
		end
	elseif dms == "ci_must_pass" or dms == "ci_still_running" then
		table.insert(checks, {
			key = "ci",
			state = dms == "ci_still_running" and "inprogress" or "warning",
			label = "Pipeline must pass",
			details = { "CI is required to merge." },
		})
	end

	return checks
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	local path = tostring(pr.repo_full_name or "")
	local iid = tonumber(pr.id)
	if path == "" or iid == nil then
		on_done(nil, "Invalid MR identifier")
		return nil
	end

	local cache_key = string.format("gitlab_pulls:merge-checks:%s!%d", path, iid)
	if not (opts or {}).force_refresh then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(MERGE_CHECKS_QUERY, { path = path, iid = tostring(iid) }, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(result).project
		local raw = json.nilify(json.safe_table(project).mergeRequest)
		if raw == nil then
			on_done(nil, "Merge request not found")
			return
		end

		local discussions_resolved = json.nilify(raw.blocking_discussions_resolved)
		local head_pipeline = json.nilify(raw.head_pipeline)
		local checks = parse_merge_checks({
			draft = raw.draft == true,
			detailed_merge_status = json.safe_str(raw.detailed_merge_status),
			blocking_discussions_resolved = discussions_resolved,
			has_conflicts = raw.has_conflicts == true,
			head_pipeline_status = head_pipeline and json.safe_str(head_pipeline.status) or nil,
		})
		service.set_memory_cache(cache_key, checks)
		on_done(checks, nil)
	end, {
		action = "Fetch MR merge state",
		project_path = path,
		iid = iid,
	})
end

return M
