local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")

local M = {}

---@param domain "pulls"|"issues"
---@param provider_id string
local function open_with(domain, provider_id)
	for _, provider in ipairs(providers.configured(domain)) do
		if provider.id == provider_id then
			require("atlas").open(domain, provider_id)
			return
		end
	end
	local name = vim.tbl_get(providers, provider_id, "name") or provider_id
	local label = domain == "pulls" and "Pull requests are" or "Issues are"
	notify.warn(label .. " not available for " .. name, { vim_notify = true })
	require("atlas").open(domain)
end

---@param domain "pulls"|"issues"
---@param target string|nil A provider ID, "." for the current repository's provider, or nil to ask.
function M.open(domain, target)
	if not target then
		require("atlas").open(domain)
		return
	end
	if target ~= "." then
		open_with(domain, target:lower())
		return
	end

	git.local_repository(nil, function(repository)
		if not repository then
			notify.warn("No supported Git repository found", { vim_notify = true })
			require("atlas").open(domain)
			return
		end
		open_with(domain, repository.provider)
	end)
end

return M
