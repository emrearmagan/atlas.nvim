local M = {}

local json = require("atlas.core.json")

---@class BitbucketRepository : AtlasRepository
---@field branches_url string|nil
---@field tags_url string|nil

---@class BitbucketRepositoryDetails : AtlasRepositoryDetails, BitbucketRepository

---@param raw table|nil
---@param fallback_workspace string|nil
---@param fallback_repo string|nil
---@return BitbucketRepository
function M.to_repository(raw, fallback_workspace, fallback_repo)
	raw = json.safe_table(raw)
	local workspace_obj = json.safe_table(raw.workspace)
	local links = json.safe_table(raw.links)
	local html_link = json.safe_table(links.html)
	local branches_link = json.safe_table(links.branches)
	local tags_link = json.safe_table(links.tags)
	local full_name = tostring(raw.full_name or "")
	local full_owner, full_repo = full_name:match("^([^/]+)/(.+)$")
	local owner = tostring(workspace_obj.slug or full_owner or fallback_workspace or "")
	local repo_name = tostring(raw.slug or full_repo or fallback_repo or raw.name or "")
	if full_name == "" then
		full_name = owner ~= "" and repo_name ~= "" and (owner .. "/" .. repo_name) or repo_name
	end

	return {
		id = full_name,
		name = tostring(raw.name or repo_name),
		full_name = full_name,
		owner = owner,
		repo_name = repo_name,
		html_url = tostring(html_link.href or ""),
		branches_url = json.safe_str(branches_link.href),
		tags_url = json.safe_str(tags_link.href),
	}
end

---@param raw table|nil
---@param fallback_workspace string|nil
---@return BitbucketRepositoryDetails
function M.to_repo_details(raw, fallback_workspace)
	raw = json.safe_table(raw)
	local mainbranch = json.safe_table(raw.mainbranch)
	local repo = M.to_repository(raw, fallback_workspace)
	---@cast repo BitbucketRepositoryDetails
	repo.description = tostring(raw.description or "")
	repo.size = tonumber(raw.size) or 0
	repo.default_branch = tostring(mainbranch.name or "")
	repo.is_private = raw.is_private == true
	repo.created_on = tostring(raw.created_on or "")
	return repo
end

return M
