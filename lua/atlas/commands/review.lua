local config = require("atlas.config")
local diff = require("atlas.pulls.diffv2")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local ui_utils = require("atlas.ui.shared.utils")
local request_scope = require("atlas.core.requests")

local M = {}

local requests = request_scope.new()

local function no_repository()
	notify.error("No supported Git repository found", { vim_notify = true })
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@return AtlasPickerPreview
local function format_preview(pr, details)
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
	vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	return {
		title = "#" .. tostring(pr.id),
		lines = lines,
	}
end

---@param info AtlasTarget|nil
local function open_repository(info)
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
	local view = provider.view_for_target(info)
	notify.info("Fetching pull requests for " .. repo_full_name .. "...", { vim_notify = true })
	requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, { force_refresh = true, pagelen = 50 }, done)
	end, function(page, errors)
		if errors and #errors > 0 then
			notify.error(table.concat(errors, "; "), { vim_notify = true })
			return
		end

		local pulls = page.items
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
				return provider.capabilities.core.fetch_pullrequest(
					pr,
					{ force_refresh = false },
					function(details, err)
						if err then
							done({ title = "#" .. tostring(pr.id), lines = { err } })
							return
						end
						done(format_preview(pr, details))
					end
				)
			end,
			on_select = function(pr)
				if not pr then
					return
				end
				diff.open_pr(pr, function(err)
					if err then
						notify.error("Unable to open diff: " .. tostring(err), { vim_notify = true })
					end
				end)
			end,
		})
	end)
end

---@param url string|nil
function M.open(url)
	requests.cancel()
	requests = request_scope.new()
	if url then
		local target, err = providers.resolve(url)
		if not target or target.domain ~= "pulls" or target.entity ~= "pr" then
			notify.error(err or "Expected a pull request URL", { vim_notify = true })
			return
		end
		diff.open_pr(target, function(open_err)
			if open_err then
				notify.error(open_err, { vim_notify = true })
			end
		end)
		return
	end
	requests.run(function(done)
		return git.repo_root(nil, done)
	end, function(root)
		if not root then
			no_repository()
			return
		end
		requests.run(function(done)
			return git.local_repository(root, done)
		end, function(info)
			open_repository(info)
		end)
	end)
end

return M
