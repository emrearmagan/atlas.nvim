local M = {}

local PROVIDER_SEARCH_MODULE = {
	jira = "atlas.issues.providers.jira.completion.search",
	github = "atlas.pulls.providers.github.completion.search",
	gitlab = "atlas.pulls.providers.gitlab.completion.search",
	bitbucket = "atlas.pulls.providers.bitbucket.completion.search",
}

---@param domain "pulls"|"issues"
---@return string[]
local function configured_provider_ids(domain)
	local config = require("atlas.config")
	local cfg = config.options and config.options[domain] or nil
	local providers = cfg and cfg.providers or {}
	local order = domain == "pulls" and { "bitbucket", "github", "gitlab" } or { "jira", "github" }
	local ids = {}
	for _, id in ipairs(order) do
		if providers[id] then
			table.insert(ids, id)
		end
	end
	return ids
end

---@return string[]
local function unique_provider_ids()
	local seen = {}
	---@type string[]
	local ids = {}

	for _, domain in ipairs({ "issues", "pulls" }) do
		for _, id in ipairs(configured_provider_ids(domain)) do
			if not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	return ids
end

---@param provider_id string
local function dispatch(provider_id)
	local module_path = PROVIDER_SEARCH_MODULE[provider_id]
	if module_path == nil then
		vim.notify(string.format("[Atlas] Search not supported for %s", provider_id), vim.log.levels.ERROR)
		return
	end
	require(module_path).open()
end

---@param provider_id string|nil
function M.run(provider_id)
	local ids = unique_provider_ids()

	if #ids == 0 then
		vim.notify("[Atlas] No providers configured", vim.log.levels.ERROR)
		return
	end

	if provider_id ~= nil and provider_id ~= "" then
		if not vim.tbl_contains(ids, provider_id) then
			vim.notify(string.format("[Atlas] Provider not configured: %s", provider_id), vim.log.levels.ERROR)
			return
		end
		dispatch(provider_id)
		return
	end

	if #ids == 1 then
		dispatch(ids[1])
		return
	end

	vim.ui.select(ids, {
		prompt = "Search in:",
		format_item = function(id)
			return id:sub(1, 1):upper() .. id:sub(2)
		end,
	}, function(choice)
		if choice == nil then
			return
		end
		dispatch(choice)
	end)
end

---@param arglead string
---@return string[]
function M.complete(arglead)
	return vim.tbl_filter(function(p)
		return p:find(arglead, 1, true) == 1
	end, unique_provider_ids())
end

return M
