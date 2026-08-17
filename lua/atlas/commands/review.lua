local M = {}

local config = require("atlas.config")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local ui_utils = require("atlas.ui.shared.utils")

local request

local function no_repository()
	notify.error("No supported Git repository found", { vim_notify = true })
end

---@param value string|nil
function M.open(value)
	if value then
		require("atlas.pulls.diff").open_pull_request(value)
		return
	end

	local root = git.repo_root()
	local info = root and git.local_repository(root, "pulls") or nil
	if not info then
		no_repository()
		return
	end
	if not providers.domain(info.provider, "pulls") or not config.provider_options(info.provider) then
		no_repository()
		return
	end

	local provider = assert(providers.load(info.provider, "pulls"))
	---@cast provider PullsProvider
	local repo_full_name = assert(info.repo_full_name, "Repository target missing repo_full_name")
	local view = provider.search_view(info)
	if request then
		request.cancel()
	end
	notify.info("Fetching pull requests for " .. repo_full_name .. "...", { vim_notify = true })
	request = provider.capabilities.core.fetch_pullrequests(view, {
		force_load = true,
		states = { "open" },
	}, function(pulls, errors)
		request = nil
		if errors and #errors > 0 then
			notify.error(table.concat(errors, "; "), { vim_notify = true })
			return
		end

		local pull_requests = {}
		for _, pr in ipairs(pulls) do
			if pr.state == "open" or pr.state == "draft" then
				table.insert(pull_requests, pr)
			end
		end
		if #pull_requests == 0 then
			notify.info("No open pull requests found for " .. repo_full_name, { vim_notify = true })
			return
		end

		picker.select_with_preview({
			title = "Review pull request",
			items = pull_requests,
			key = function(pr)
				return tostring(pr.id)
			end,
			format_item = function(pr)
				return string.format("#%s %s", tostring(pr.id), pr.title)
			end,
			preview_item = function(pr, done)
				return provider.capabilities.core.fetch_pullrequest(pr, { force_load = false }, function(details, err)
					if err then
						done({ title = "#" .. tostring(pr.id), lines = { err } })
						return
					end
					local author = pr.author.username ~= "" and "@" .. pr.author.username or pr.author.name
					local status = pr.state .. "   updated " .. ui_utils.relative_time(pr.updated_on)
					if pr.lines_added ~= nil and pr.lines_removed ~= nil then
						status = status .. string.format("   +%d -%d", pr.lines_added, pr.lines_removed)
					end
					local description = ui_utils.strip_markup(details and details.description or "")
					local lines = {
						author,
						pr.source.branch .. " → " .. pr.destination.branch,
						status,
						"",
					}
					vim.list_extend(
						lines,
						vim.split(description ~= "" and description or "No description", "\n", { plain = true })
					)
					done({
						title = "#" .. tostring(pr.id),
						lines = lines,
					})
				end)
			end,
			on_select = function(pr)
				if not pr then
					return
				end
				require("atlas.pulls.diff").open_pr({
					provider = provider,
					ref = pr,
					current_user = nil,
					root = root,
				}, function(err)
					if err then
						notify.error("Unable to open diff: " .. tostring(err), { vim_notify = true })
					end
				end)
			end,
		})
	end)
end

return M
