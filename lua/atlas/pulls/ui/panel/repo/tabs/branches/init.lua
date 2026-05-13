---@class PullsRepoBranchesTab : PullsRepoPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local layout = require("atlas.ui.layout")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local threads = require("atlas.ui.components.threadsv2")
local state = require("atlas.pulls.ui.panel.repo.tabs.branches.state")
local repo_panel_state = require("atlas.pulls.ui.panel.repo.state")
local core_utils = require("atlas.core.utils")
local keymaps = require("atlas.pulls.ui.panel.repo.tabs.branches.keymaps")

local PADDING_X = 1

---@type { cancel: fun() }|nil
local request = nil
---@type { cancel: fun() }|nil
local delete_request = nil

local function stop_request()
	if request ~= nil then
		request.cancel()
		request = nil
	end
	if delete_request ~= nil then
		delete_request.cancel()
		delete_request = nil
	end
end

---@return table|nil
local function cursor_entry()
	local win = layout.win_id("detail")
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return (repo_panel_state.line_map or {})[lnum]
end

---@param repo PullsRepoDetails
---@return AtlasThreadV2Item[]
local function to_items(repo)
	local items = {}
	for _, branch in ipairs((state.branches or {}).entries or {}) do
		local msg = branch.message and tostring(branch.message:match("^[^\n\r]*") or "") or nil
		if msg == "" then msg = nil end
		local author = branch.author and tostring(branch.author) or nil
		if author == "" then author = nil end
		table.insert(items, {
			icon = icons.pulls("branch"),
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
		if repo_panel_state.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if state.branches == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading branches..."), "AtlasTextMuted", PADDING_X)
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
	state.line_map = line_map
	return lines, spans, line_map
end

---@param _pr PullRequest|nil
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts PullsFetchOpts|nil
function M.on_select(_pr, repo, refresh, opts)
	opts = opts or {}
	local detail = require("atlas.pulls.ui.panel.repo.state").current_repo_details
	if repo == nil then
		state.reset()
		refresh()
		return
	end
	if detail == "loading" then
		state.branches = "loading"
		refresh()
		return
	end
	if type(detail) ~= "table" then
		state.reset()
		refresh()
		return
	end

	local prev_name = state.repo and state.repo.full_name or ""
	local next_name = tostring(detail.full_name or "")
	local repo_label = next_name ~= "" and next_name or tostring(repo.name or repo.id or "")
	local should_fetch = opts.force_refresh == true or state.branches == nil or state.branches == "loading" or prev_name ~= next_name
	state.repo = detail
	if not should_fetch then
		refresh()
		return
	end

	stop_request()
	state.branches = "loading"
	footer.notify("loading", string.format("Loading branches for %s...", repo_label))
	refresh()

	local provider = require("atlas.pulls.state").provider
	if provider == nil or type(provider.fetch_repo_branches) ~= "function" then
		state.branches = { entries = {} }
		footer.notify("error", "Branch listing is not supported by this provider")
		refresh()
		return
	end

	request = provider.fetch_repo_branches(detail, {
		force_load = opts.force_load == true or opts.force_refresh == true,
		pagelen = opts.pagelen,
	}, function(branches, err)
		request = nil
		local active_detail = require("atlas.pulls.ui.panel.repo.state").current_repo_details
		if type(active_detail) ~= "table" or tostring(active_detail.full_name or "") ~= next_name then
			return
		end
		state.repo = active_detail
		if err then
			state.branches = { entries = {} }
			footer.notify("error", string.format("Failed to load branches for %s", repo_label))
		else
			state.branches = branches or { entries = {} }
			footer.notify("success", string.format("Branches loaded for %s", repo_label), 1200)
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
	local provider = require("atlas.pulls.state").provider
	if provider == nil or type(provider.delete_repo_branch) ~= "function" then
		footer.notify("error", "Branch deletion is not supported by this provider")
		return
	end

	local entry = cursor_entry()
	local branch = entry and entry.item and entry.item.obj and entry.item.obj.branch
	local repo = state.repo
	if type(repo) ~= "table" or type(branch) ~= "table" then
		footer.notify("warn", "No branch selected")
		return
	end

	local branch_name = tostring(branch.name or "")
	if branch_name == "" then
		footer.notify("warn", "Branch name is missing")
		return
	end
	if branch_name == tostring(repo.default_branch or "") then
		footer.notify("warn", "Refusing to delete the default branch")
		return
	end

	vim.ui.input({ prompt = string.format("Delete branch '%s'? [y/N]: ", branch_name) }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end

		footer.notify("loading", string.format("Deleting branch %s...", branch_name))
		delete_request = provider.delete_repo_branch(repo, branch, function(ok, err)
			delete_request = nil
			if err ~= nil then
				footer.notify("error", "Delete branch failed: " .. tostring(err))
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

			footer.notify("success", string.format("Deleted branch %s", branch_name), 1200)
			refresh()
		end)
	end)
end

function M.deactivate(buf)
	stop_request()
	if buf ~= nil then
		keymaps.teardown(buf)
	end
end

return M
