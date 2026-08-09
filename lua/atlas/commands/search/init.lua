local M = {}

local notify = require("atlas.core.notify")
local providers = require("atlas.providers")

local domain_labels = {
	pulls = "Pull Requests",
	issues = "Issues",
}

---@class AtlasSearchEntry
---@field id AtlasProviderId
---@field label string
---@field open fun()

---@param provider PullsProvider
---@return fun()|nil
local function pulls_search(provider)
	local actions = require("atlas.pulls.actions")
	local context = { provider = provider }
	if not actions.is_available("search", context) then
		return nil
	end
	return function()
		actions.run("search", context)
	end
end

---@param provider IssuesProvider
---@return fun()|nil
local function issues_search(provider)
	local actions = require("atlas.issues.actions")
	local context = { provider = provider }
	if not actions.is_available("search", context) then
		return nil
	end
	return function()
		actions.run("search", context)
	end
end

---@return AtlasSearchEntry[]
local function configured_searches()
	local entries = {}
	for _, provider_config in ipairs(providers.list()) do
		for _, domain in ipairs({ "pulls", "issues" }) do
			if provider_config.domains[domain] and providers.options(provider_config.id, domain) then
				local provider = assert(providers.load(provider_config.id, domain))
				local search
				if domain == "pulls" then
					---@cast provider PullsProvider
					search = pulls_search(provider)
				else
					---@cast provider IssuesProvider
					search = issues_search(provider)
				end
				if search then
					table.insert(entries, {
						id = provider_config.id,
						label = provider_config.name .. " " .. domain_labels[domain],
						open = search,
					})
				end
			end
		end
	end
	return entries
end

---@param entries AtlasSearchEntry[]
---@param prompt string
local function choose(entries, prompt)
	if #entries == 1 then
		entries[1].open()
		return
	end

	vim.ui.select(entries, {
		prompt = prompt,
		format_item = function(entry)
			return entry.label
		end,
	}, function(entry)
		if entry then
			entry.open()
		end
	end)
end

---@param provider_id AtlasProviderId|nil
function M.run(provider_id)
	local entries = configured_searches()
	if provider_id then
		local matches = {}
		for _, entry in ipairs(entries) do
			if entry.id == provider_id then
				table.insert(matches, entry)
			end
		end
		if #matches == 0 then
			notify.error("No configured search for provider: " .. provider_id)
			return
		end
		choose(matches, "Search " .. providers[provider_id].name .. " in:")
		return
	end

	if #entries == 0 then
		notify.error("No searchable providers configured")
		return
	end
	choose(entries, "Search in:")
end

---@param arglead string
---@return string[]
function M.complete(arglead)
	local result, seen = {}, {}
	for _, entry in ipairs(configured_searches()) do
		if not seen[entry.id] and entry.id:find(arglead, 1, true) == 1 then
			seen[entry.id] = true
			table.insert(result, entry.id)
		end
	end
	return result
end

return M
