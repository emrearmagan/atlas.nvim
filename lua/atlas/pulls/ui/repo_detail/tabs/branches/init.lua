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
local picker = require("atlas.ui.picker")
local navigation = require("atlas.pulls.ui.repo_detail.navigation")

local PADDING_X = 1

---@class PullsRepoBranchesTabState
---@field repo AtlasRepositoryDetails|nil
---@field branches AtlasRepositoryBranch[]|"loading"|string|nil
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field requests AtlasRequestScope
local state = { repo = nil, branches = nil, page = 1, cursors = {}, requests = request_scope.new() }

local function reset_state()
	state.repo = nil
	state.branches = nil
	state.page = 1
	state.cursors = {}
	state.next_cursor = nil
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

---@param repo AtlasRepository|nil
---@return boolean
local function is_current_repo(repo)
	local current = detail.current_repo
	return current ~= nil and repo ~= nil and current.id == repo.id
end

---@param repo AtlasRepositoryDetails
---@param branches AtlasRepositoryBranch[]
---@return AtlasThreadV2Item[]
local function to_items(repo, branches)
	local items = {}
	for _, branch in ipairs(branches) do
		local msg = branch.message and branch.message:match("^[^\n\r]*")
		if msg == "" then
			msg = nil
		end
		local author = branch.author
		if author == "" then
			author = nil
		end
		local branch_icon = icons.pulls("branch")
		table.insert(items, {
			icon = branch_icon,
			author = branch.name,
			additional = author,
			right_text = branch.date and utils.relative_time_text(branch.date) or nil,
			content = msg,
			obj = { repo = repo, branch = branch },
		})
	end
	return items
end

---@param _repo AtlasRepository
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_repo, width)
	local lines = {}
	local spans = {}
	local line_map = {}
	local branches = state.branches

	if branches == nil then
		if detail.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if branches == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading branches..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(branches) == "string" then
		utils.push(lines, spans, branches, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local repo = state.repo
	if repo == nil then
		utils.push(lines, spans, "No branches loaded.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if #branches == 0 then
		utils.push(lines, spans, "No branches found.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local thread_lines, thread_spans, thread_map = threads.render(to_items(repo, branches), width, {
		padding_x = PADDING_X,
		mode = "linked",
		content_max_lines = 1,
		author_hl = function()
			return "Normal"
		end,
		content_hl = function(_, row)
			return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
		end,
	})

	utils.append_block(lines, spans, { lines = thread_lines, highlights = thread_spans })
	line_map = thread_map or {}
	return lines, spans, line_map
end

---@param refresh fun()
local function load_page(refresh)
	local repo = state.repo
	if repo == nil then
		return
	end
	local repo_name = repo.full_name
	stop_requests()
	state.branches = "loading"
	state.next_cursor = nil
	notify.loading(string.format("Loading branches for %s...", repo_name))
	refresh()

	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repository == nil then
		state.branches = {}
		notify.error("Branch listing is not supported by this provider")
		refresh()
		return
	end

	state.requests.run(function(done)
		return repository.fetch_branches(repo, {
			cursor = state.cursors[state.page],
		}, done)
	end, function(branches, err, next_cursor)
		local active_detail = detail.current_repo_details
		if type(active_detail) ~= "table" or active_detail.full_name ~= repo_name then
			return
		end
		state.repo = active_detail
		if err then
			state.branches = err
			notify.error(string.format("Failed to load branches for %s", repo_name))
		else
			state.branches = branches or {}
			state.next_cursor = next_cursor
			notify.success(string.format("Branches loaded for %s", repo_name), { timeout = 1200 })
		end
		refresh()
	end)
end

---@param repo AtlasRepository|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(repo, refresh, opts)
	opts = opts or {}
	local repo_details = detail.current_repo_details
	if repo_details == "loading" then
		state.branches = "loading"
		refresh()
		return
	end
	if repo == nil or type(repo_details) ~= "table" then
		M.reset()
		refresh()
		return
	end
	local changed = state.repo == nil or state.repo.full_name ~= repo_details.full_name
	local should_fetch = opts.force_refresh == true or changed or state.branches == nil or state.branches == "loading"
	if changed or opts.force_refresh then
		reset_state()
	end
	state.repo = repo_details
	if should_fetch then
		load_page(refresh)
	else
		refresh()
	end
end

---@param direction integer
---@param refresh fun()
function M.change_page(direction, refresh)
	if state.branches == "loading" or state.repo == nil then
		return
	end
	if direction > 0 then
		if state.next_cursor == nil then
			return
		end
		state.cursors[state.page + 1] = state.next_cursor
		state.page = state.page + 1
	elseif state.page > 1 then
		state.page = state.page - 1
	else
		return
	end
	load_page(refresh)
end

---@param refresh fun()
function M.search(refresh)
	local repo = state.repo
	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repo == nil or repository == nil then
		return
	end
	local current_repo = detail.current_repo
	picker.search({
		title = "Branches",
		fetch_on_open = true,
		key = function(branch)
			return branch.name
		end,
		format_item = function(branch)
			return branch.name
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_branches(repo, { search = query }, finish)
			end, done)
		end,
		on_select = function(branch)
			if branch == nil or not is_current_repo(current_repo) or detail.current_tab ~= "branches" then
				return
			end
			local win = detail.win
			if win == nil or not vim.api.nvim_win_is_valid(win) then
				return
			end
			for row, entry in pairs(detail.line_map) do
				local item = entry.item and entry.item.obj and entry.item.obj.branch
				if entry.kind == "header" and item and item.name == branch.name then
					vim.api.nvim_set_current_win(win)
					vim.api.nvim_win_set_cursor(win, { row, 0 })
					return
				end
			end
			stop_requests()
			state.branches = { branch }
			state.page = 1
			state.cursors = {}
			state.next_cursor = nil
			refresh()
			navigation.focus_first()
		end,
	})
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
	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	keymaps.setup(buf, {
		search = function()
			M.search(refresh)
		end,
		next_page = function()
			M.change_page(1, refresh)
		end,
		previous_page = function()
			M.change_page(-1, refresh)
		end,
		delete = repository and repository.delete_branch and function()
			M.delete_current_branch(refresh)
		end or nil,
	})
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

	local branch_name = branch.name
	if branch_name == "" then
		notify.warn("Branch name is missing")
		return
	end
	if branch_name == repo.default_branch then
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
				notify.error("Delete branch failed: " .. err)
				return
			end

			if ok then
				local branches = core_utils.as_table(state.branches) or {}
				for i, existing in ipairs(branches) do
					if existing.name == branch_name then
						table.remove(branches, i)
						break
					end
				end
				state.branches = branches
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
