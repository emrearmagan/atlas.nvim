local M = {}

local highlights = require("atlas.ui.shared.highlights")

---@param name string|nil
---@return string
function M.author_hl(name)
	if name == nil then
		return "AtlasTextMuted"
	end
	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unknown" or lower == "none" then
		return "AtlasTextMuted"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param user { name: string?, nickname: string?, username: string? }|nil
---@return string
function M.user_handle(user)
	if user == nil then
		return "Unknown"
	end
	if user.nickname and user.nickname ~= "" then
		return user.nickname
	end
	if user.username and user.username ~= "" then
		return user.username
	end
	return (user.name and user.name ~= "") and user.name or "Unknown"
end

---@param repo string|nil
---@return string
function M.repo_hl(repo)
	if repo == nil then
		return "AtlasTextMuted"
	end
	local lower = vim.trim(repo):lower()
	if lower == "" or lower == "none" then
		return "AtlasTextMuted"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param pr_state string|nil
---@return string
function M.pr_state_hl(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "AtlasPROpenChip"
	end
	if lower == "merged" then
		return "AtlasPRMergedChip"
	end
	if lower == "declined" then
		return "AtlasPRDeclinedChip"
	end
	if lower == "draft" then
		return "AtlasPRDraftChip"
	end
	return "AtlasTextMuted"
end

return M
