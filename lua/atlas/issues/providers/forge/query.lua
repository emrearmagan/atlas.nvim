local M = {}

local syntax = require("atlas.providers.forge.query")
local STATES = { open = true, closed = true, all = true }
local SCOPES = { assigned = true, created = true, mentioned = true, all = true }
local FIELDS = { repo = "repo", state = "is", scope = "scope", labels = "labels", label = "labels", type = "type" }

---@param view AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig
---@return string
function M.resolve(view)
	local parts = {}
	local repo = vim.trim(view.repo or "")
	syntax.append(parts, repo ~= "" and "repo" or "type", repo ~= "" and repo or "issues")
	syntax.append(parts, "is", view.state or "open")
	if view.scope and view.scope ~= "all" and view.scope ~= "" then
		syntax.append(parts, "scope", view.scope)
	end
	if view.labels and view.labels ~= "" then
		syntax.append(parts, "labels", view.labels)
	end
	local keys = vim.tbl_keys(view.extra_params or {})
	table.sort(keys)
	for _, key in ipairs(keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			syntax.append(parts, "param." .. key, value)
		end
	end
	if view.search and view.search ~= "" then
		syntax.append(parts, "search", view.search)
	end
	return table.concat(parts, " ")
end

---@param view AtlasGiteaIssuesViewConfig|AtlasForgejoIssuesViewConfig
---@param source string
---@return boolean, string|nil
function M.apply(view, source)
	local parsed, err = syntax.parse(source, FIELDS)
	if not parsed then
		return false, err
	end
	if parsed.repo and not parsed.repo:match("^[^/%s]+/[^/%s]+$") then
		return false, "Invalid repository: " .. parsed.repo
	end
	for _, state in ipairs(parsed.states) do
		if not STATES[state:lower()] then
			return false, "Invalid issue state: " .. state
		end
	end
	if parsed.scope and not SCOPES[parsed.scope:lower()] then
		return false, "Invalid issue scope: " .. parsed.scope
	end
	if parsed.type and parsed.type:lower() ~= "issues" then
		return false, "Invalid issue type: " .. parsed.type
	end
	view.repo = parsed.repo
	view.state = parsed.states[#parsed.states] and parsed.states[#parsed.states]:lower() or nil
	view.scope = parsed.scope and parsed.scope:lower() or nil
	view.labels = parsed.labels
	view.extra_params = parsed.extra_params
	view.search = parsed.search
	view.current_repo = nil
	return true, nil
end

return M
