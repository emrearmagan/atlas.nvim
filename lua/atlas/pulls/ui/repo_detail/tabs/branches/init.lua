local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local notify = require("atlas.core.notify")
local threads = require("atlas.ui.components.threadsv2")
local detail = require("atlas.pulls.ui.repo_detail.state")
local core_utils = require("atlas.core.utils")
local keymaps = require("atlas.pulls.ui.repo_detail.tabs.branches.keymaps")
local request_scope = require("atlas.core.requests")

local PADDING_X = 1

---@class PullsRepoBranchesTabState
---@field repo PullsRepoDetails|nil
---@field branches PullsRepoBranches|"loading"|string|nil
---@field requests AtlasRequestScope
local state = { repo = nil, branches = nil, requests = request_scope.new() }

local function reset_state()
	state.repo = nil
	state.branches = nil
end

local function stop_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

function M.reset()
	stop_requests()
	reset_state()
end

---@return table|nil
local function cursor_entry()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return detail.line_map[lnum]
end

---@param repo PullsRepo|nil
---@return boolean
local function is_current_repo(repo)
	local current = detail.current_repo
	return current ~= nil and tostring(current.id or "") == tostring(repo and repo.id or "")
end

---@param repo PullsRepoDetails
---@return AtlasThreadV2Item[]
local function to_items(repo)
	local items = {}
	for _, branch in ipairs((state.branches or {}).entries or {}) do
		local msg = branch.message and tostring(branch.message:match("^[^\n\r]*") or "") or nil
		if msg == "" then
			msg = nil
		end
		local author = branch.author and tostring(branch.author) or nil
		if author == "" then
			author = nil
		end
		local branch_icon = icons.pulls("branch")
		table.insert(items, {
			icon = branch_icon,
			author = tostring(branch.name or ""),
			additional = author,
			right_text = branch.date and utils.relative_time_text(branch.date) or nil,
			content = msg,
			obj = { repo = repo, branch = branch },
		})
	end
	return items
end

---@param _repo PullsRepo
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.branches == nil then
		if detail.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if state.branches == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading branches..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(state.branches) == "string" then
		utils.push(lines, spans, state.branches, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local repo = state.repo
	if repo == nil then
		utils.push(lines, spans, "No branches loaded.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local entries = state.branches.entries or {}
	if #entries == 0 then
		utils.push(lines, spans, "No branches found.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local thread_lines, thread_spans, thread_map = threads.render(to_items(repo), width, {
		padding_x = PADDING_X,
		mode = "linked",
		content_max_lines = 1,
		author_hl = function()
			return "AtlasText"
		end,
		content_hl = function(_, row)
			return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
		end,
	})

	utils.append_block(lines, spans, { lines = thread_lines, highlights = thread_spans })
	line_map = thread_map or {}
	return lines, spans, line_map
end

---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(repo, refresh, opts)
	opts = opts or {}
	local repo_details = detail.current_repo_details
	if repo == nil then
		reset_state()
		refresh()
		return
	end
	if repo_details == "loading" then
		state.branches = "loading"
		refresh()
		return
	end
	if type(repo_details) ~= "table" then
		reset_state()
		refresh()
		return
	end

	local prev_name = state.repo and state.repo.full_name or ""
	local next_name = tostring(repo_details.full_name or "")
	local repo_label = next_name ~= "" and next_name or tostring(repo.name or repo.id or "")
	local should_fetch = opts.force_refresh == true
		or state.branches == nil
		or state.branches == "loading"
		or prev_name ~= next_name
	state.repo = repo_details
	if not should_fetch then
		refresh()
		return
	end

	stop_requests()
	state.branches = "loading"
	notify.loading(string.format("Loading branches for %s...", repo_label))
	refresh()

	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repository == nil then
		state.branches = { entries = {} }
		notify.error("Branch listing is not supported by this provider")
		refresh()
		return
	end

	state.requests.run(function(done)
		return repository.fetch_branches(repo_details, {
			force_refresh = opts.force_refresh == true,
		}, done)
	end, function(branches, err)
		local active_detail = detail.current_repo_details
		if type(active_detail) ~= "table" or tostring(active_detail.full_name or "") ~= next_name then
			return
		end
		state.repo = active_detail
		if err then
			state.branches = tostring(err)
			notify.error(string.format("Failed to load branches for %s", repo_label))
		else
			state.branches = branches or { entries = {} }
			notify.success(string.format("Branches loaded for %s", repo_label), { timeout = 1200 })
		end
		refresh()
	end)
end

---@return boolean
function M.is_loading()
	return state.branches == "loading"
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "header"
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

---@param refresh fun()
function M.delete_current_branch(refresh)
	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repository == nil or not repository.delete_branch then
		notify.error("Branch deletion is not supported by this provider")
		return
	end

	local entry = cursor_entry()
	local branch = entry and entry.item and entry.item.obj and entry.item.obj.branch
	local repo = state.repo
	if repo == nil or branch == nil then
		notify.warn("No branch selected")
		return
	end

	local branch_name = tostring(branch.name or "")
	if branch_name == "" then
		notify.warn("Branch name is missing")
		return
	end
	if branch_name == tostring(repo.default_branch or "") then
		notify.warn("Refusing to delete the default branch")
		return
	end

	local current_repo = detail.current_repo
	vim.ui.input({ prompt = string.format("Delete branch '%s'? [y/N]: ", branch_name) }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if (confirmed ~= "y" and confirmed ~= "yes") or not is_current_repo(current_repo) then
			return
		end

		notify.loading(string.format("Deleting branch %s...", branch_name))
		stop_requests()
		state.requests.run(function(done)
			return repository.delete_branch(repo, branch, done)
		end, function(ok, err)
			if not is_current_repo(current_repo) then
				return
			end
			if err ~= nil then
				notify.error("Delete branch failed: " .. tostring(err))
				return
			end

			if ok then
				local branches = core_utils.as_table(state.branches) or {}
				local entries = core_utils.as_table(branches.entries) or {}
				for i, existing in ipairs(entries) do
					if tostring(existing.name or "") == branch_name then
						table.remove(entries, i)
						break
					end
				end
				state.branches = { entries = entries }
			end

			notify.success(string.format("Deleted branch %s", branch_name), { timeout = 1200 })
			refresh()
		end)
	end)
end

function M.deactivate(buf)
	stop_requests()
	if buf ~= nil then
		keymaps.teardown(buf)
	end
end

return M
