local M = {}

local picker = require("atlas.ui.picker")
local query = require("atlas.issues.providers.forge.query")
local search_prompt = require("atlas.providers.forge.completion.search")

---@param provider_id ForgeProviderId
---@param api ForgeIssuesApi
function M.new(provider_id, api)
	local name = provider_id == "gitea" and "Gitea" or "Forgejo"
	local actions = {}

	local function select_repository(title, include_all, on_select, on_cancel)
		local initial = include_all and { { label = "All repositories", repo = "" } } or {}
		picker.search({
			title = title,
			initial_items = initial,
			fetch_on_open = false,
			format_item = function(item)
				return item.label
			end,
			fetch = function(term, done)
				if vim.trim(term) == "" then
					done(initial, nil)
					return nil
				end
				return api.search_repositories(term, function(repositories, err)
					if err then
						done(nil, err)
						return
					end
					local items = {}
					for _, repo in ipairs(repositories or {}) do
						items[#items + 1] = { id = repo, label = repo, repo = repo }
					end
					done(items, nil)
				end)
			end,
			on_select = function(item)
				on_select(item.repo)
			end,
			on_cancel = on_cancel,
		})
	end

	local function preview(item, done)
		local issue = item.value
		return api.get(issue, {}, function(details, err)
			if err or not details then
				done({ title = issue.key, lines = { err or "Failed to load issue" } })
				return
			end
			local assignees, labels = {}, {}
			for _, user in ipairs(details.assignees or {}) do
				assignees[#assignees + 1] = "@" .. tostring(user.account_id or user.display_name)
			end
			for _, label in ipairs(details.labels or {}) do
				labels[#labels + 1] = label.name
			end
			local lines = {
				"**Status:** " .. tostring(issue.status or "Open"),
				"**Author:** " .. (issue.reporter and issue.reporter.display_name or "Unknown"),
				"**Assignees:** " .. (#assignees > 0 and table.concat(assignees, ", ") or "Unassigned"),
			}
			if #labels > 0 then
				lines[#lines + 1] = "**Labels:** " .. table.concat(labels, ", ")
			end
			if details.milestone then
				lines[#lines + 1] = "**Milestone:** " .. details.milestone.title
			end
			vim.list_extend(lines, { "", "## Description", "" })
			local description = vim.trim(details.description or "")
			vim.list_extend(
				lines,
				vim.split(description ~= "" and description or "No description", "\n", { plain = true })
			)
			done({ title = issue.key .. " - " .. issue.title, lines = lines })
		end)
	end

	function actions.search(ctx, done)
		local function cancel()
			done(nil, nil)
		end
		select_repository("Search Issues - Repository", true, function(repo)
			picker.search({
				title = repo ~= "" and ("Search " .. repo .. " Issues") or ("Search " .. name .. " Issues"),
				fetch_on_open = false,
				format_item = function(item)
					return item.label
				end,
				preview_item = preview,
				fetch = function(term, fetch_done)
					term = vim.trim(term)
					if term == "" then
						fetch_done({}, nil)
						return nil
					end
					local view = {}
					local ok, parse_err = query.apply(view, term)
					if not ok then
						fetch_done(nil, parse_err)
						return nil
					end
					view.repo = view.repo or repo
					view.state = view.state or "all"
					return api.list(view, { pagelen = 30 }, function(page, err)
						if err then
							fetch_done(nil, err)
							return
						end
						local items = {}
						for _, issue in ipairs(page.items) do
							items[#items + 1] =
								{ id = issue.key, label = issue.key .. " - " .. issue.title, value = issue }
						end
						fetch_done(items, nil)
					end)
				end,
				on_select = function(item)
					require("atlas.issues.ui.detail").open(item.value, { provider = ctx.provider })
					done(nil, nil)
				end,
				on_cancel = cancel,
			})
		end, cancel)
	end

	function actions.open_repo(_, done)
		select_repository("Open Repo", false, function(repo)
			require("atlas").open("issues", provider_id, {
				initial_view = { name = "Search", layout = "compact", repo = repo, state = "all" },
			})
			done(nil, nil)
		end, function()
			done(nil, nil)
		end)
	end

	function actions.can_edit()
		local state = require("atlas.issues.state")
		return state.provider ~= nil and state.provider.id == provider_id and state.search_view() ~= nil,
			"No active " .. name .. " issue search"
	end

	function actions.edit(_, done)
		local state = require("atlas.issues.state")
		local view = state.search_view()
		if actions.can_edit() then
			search_prompt.edit(provider_id, "issues", query.resolve(view) .. " ", function(value)
				if not actions.can_edit() or state.search_view() ~= view then
					return
				end
				local ok, err = query.apply(view, value)
				if not ok then
					require("atlas.core.notify").error(err)
					return
				end
				require("atlas.issues.ui.dashboard.controller").refresh_view()
			end)
		end
		done(nil, nil)
	end

	return actions
end

return M
