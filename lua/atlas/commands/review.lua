local M = {}

local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local providers = require("atlas.providers")
local resolver = require("atlas.providers.resolve")

local request

local function no_repository()
	notify.error("No supported Git repository found. Use :Atlas pulls instead.")
end

---@param value string|nil
function M.open(value)
	if value then
		require("atlas.pulls.diff").open_pull_request(value)
		return
	end

	local root = git.repo_root()
	local info = root and git.local_repository(root) or nil
	if not info then
		no_repository()
		return
	end
	if not providers.domain(info.provider, "pulls") or not providers.options(info.provider, "pulls") then
		no_repository()
		return
	end

	local provider = assert(providers.load(info.provider, "pulls"))
	---@cast provider PullsProvider
	local target = resolver.target(info, "pulls", "repo", nil)
	local view = provider.search_view(target)
	if request then
		request.cancel()
	end
	request = provider.capabilities.core.fetch_pullrequests(view, {
		force_load = true,
		state = "open",
	}, function(groups, errors)
		request = nil
		if errors and #errors > 0 then
			notify.error(table.concat(errors, "; "))
			return
		end

		local pull_requests = {}
		for _, group in ipairs(groups or {}) do
			for _, pr in ipairs(group.prs or {}) do
				if pr.state == "open" or pr.state == "draft" then
					table.insert(pull_requests, pr)
				end
			end
		end
		if #pull_requests == 0 then
			notify.info("No open pull requests found for " .. info.slug)
			return
		end

		vim.ui.select(pull_requests, {
			prompt = "Review pull request",
			format_item = function(pr)
				return string.format("#%s %s", tostring(pr.id), pr.title)
			end,
		}, function(pr)
			if not pr then
				return
			end
			require("atlas.pulls.diff").open_pr({
				provider = provider,
				pr = pr,
				current_user = nil,
				root = root,
			}, function(err)
				if err then
					notify.error("Unable to open diff: " .. tostring(err))
				end
			end)
		end)
	end)
end

return M
