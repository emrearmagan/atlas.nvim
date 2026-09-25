local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local notify = require("atlas.core.notify")
local threads = require("atlas.ui.components.threadsv2")
local detail = require("atlas.pulls.ui.repo_detail.state")
local request_scope = require("atlas.core.requests")
local picker = require("atlas.ui.picker")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local navigation = require("atlas.pulls.ui.repo_detail.navigation")

local PADDING_X = 1

---@class PullsRepoTagsTabState
---@field repo AtlasRepositoryDetails|nil
---@field tags AtlasRepositoryTag[]|"loading"|string|nil
---@field page integer
---@field cursors table<integer, string>
---@field next_cursor string|nil
---@field requests AtlasRequestScope
local state = { repo = nil, tags = nil, page = 1, cursors = {}, requests = request_scope.new() }

local function reset_state()
	state.repo = nil
	state.tags = nil
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

---@param repo AtlasRepositoryDetails
---@param tags AtlasRepositoryTag[]
---@return AtlasThreadV2Item[]
local function to_items(repo, tags)
	local items = {}
	for _, tag in ipairs(tags) do
		local first_line = tag.message and tostring(tag.message:match("^[^\n\r]*") or "") or nil
		if first_line == "" then
			first_line = nil
		end
		local author_str = tag.author and tostring(tag.author) or nil
		if author_str == "" then
			author_str = nil
		end
		local content = nil
		if author_str and first_line then
			content = author_str .. "  " .. first_line
		elseif first_line then
			content = first_line
		elseif author_str then
			content = author_str
		end
		local tag_icon = icons.pulls("tag")
		table.insert(items, {
			icon = tag_icon,
			author = tostring(tag.name or ""),
			additional = tag.hash and tostring(tag.hash):sub(1, 8) or nil,
			right_text = tag.tag_date and utils.relative_time_text(tag.tag_date) or "—",
			content = content,
			obj = { repo = repo, tag = tag },
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
	local tags = state.tags

	if tags == nil then
		if detail.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if tags == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading tags..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(tags) == "string" then
		utils.push(lines, spans, tags, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local repo = state.repo
	if repo == nil then
		utils.push(lines, spans, "No tags loaded.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if #tags == 0 then
		utils.push(lines, spans, "No tags found.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local thread_lines, thread_spans, thread_map = threads.render(to_items(repo, tags), width, {
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
	local repo_name = tostring(repo.full_name or "")
	local repo_label = repo_name ~= "" and repo_name or tostring(repo.name or repo.id or "")
	stop_requests()
	state.tags = "loading"
	state.next_cursor = nil
	notify.loading(string.format("Loading tags for %s...", repo_label))
	refresh()

	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repository == nil or repository.fetch_tags == nil then
		state.tags = {}
		notify.error("Tag listing is not supported by this provider")
		refresh()
		return
	end

	state.requests.run(function(done)
		return repository.fetch_tags(repo, {
			cursor = state.cursors[state.page],
		}, done)
	end, function(tags, err, next_cursor)
		local active_detail = detail.current_repo_details
		if type(active_detail) ~= "table" or tostring(active_detail.full_name or "") ~= repo_name then
			return
		end
		state.repo = active_detail
		if err then
			state.tags = tostring(err)
			notify.error(string.format("Failed to load tags for %s", repo_label))
		else
			state.tags = tags or {}
			state.next_cursor = next_cursor
			notify.success(string.format("Tags loaded for %s", repo_label), { timeout = 1200 })
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
		state.tags = "loading"
		refresh()
		return
	end
	if repo == nil or type(repo_details) ~= "table" then
		M.reset()
		refresh()
		return
	end
	local changed = state.repo == nil or state.repo.full_name ~= repo_details.full_name
	local should_fetch = opts.force_refresh == true or changed or state.tags == nil or state.tags == "loading"
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
local function change_page(direction, refresh)
	if state.tags == "loading" or state.repo == nil then
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
local function search(refresh)
	local repo = state.repo
	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repo == nil or repository == nil or repository.fetch_tags == nil then
		return
	end
	picker.search({
		title = "Tags",
		fetch_on_open = true,
		key = function(tag)
			return tag.name
		end,
		format_item = function(tag)
			return tag.name
		end,
		fetch = function(query, done)
			return state.requests.run(function(finish)
				return repository.fetch_tags(repo, { search = query }, finish)
			end, function(tags, err)
				done(tags, err)
			end)
		end,
		on_select = function(tag)
			local current_repo = detail.current_repo_details
			if
				tag == nil
				or type(current_repo) ~= "table"
				or current_repo.full_name ~= repo.full_name
				or detail.current_tab ~= "tags"
			then
				return
			end
			local win = detail.win
			if win == nil or not vim.api.nvim_win_is_valid(win) then
				return
			end
			for row, entry in pairs(detail.line_map) do
				local item = entry.item and entry.item.obj and entry.item.obj.tag
				if entry.kind == "header" and item and item.name == tag.name then
					vim.api.nvim_set_current_win(win)
					vim.api.nvim_win_set_cursor(win, { row, 0 })
					return
				end
			end
			stop_requests()
			state.tags = { tag }
			state.page = 1
			state.cursors = {}
			state.next_cursor = nil
			refresh()
			navigation.focus_first()
		end,
	})
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	local actions = {
		{
			"ui.search",
			"Find tag",
			function()
				search(refresh)
			end,
		},
		{
			"ui.next_page",
			"Next tag page",
			function()
				change_page(1, refresh)
			end,
		},
		{
			"ui.previous_page",
			"Previous tag page",
			function()
				change_page(-1, refresh)
			end,
		},
	}
	local items = {}
	for _, action in ipairs(actions) do
		local keys = resolver.resolve(action[1])
		if keys then
			table.insert(items, {
				key = #keys == 1 and keys[1] or keys,
				desc = action[2],
				opts = { nowait = true, silent = true },
				callback = action[3],
			})
		end
	end
	help.register("Tags", items, { index = 212, buffer = buf })
end

---@param buf integer|nil
function M.deactivate(buf)
	stop_requests()
	if buf == nil then
		return
	end
	local items = {}
	for _, action in ipairs({ "ui.search", "ui.next_page", "ui.previous_page" }) do
		local keys = resolver.resolve(action)
		if keys then
			table.insert(items, { key = #keys == 1 and keys[1] or keys })
		end
	end
	help.remove("Tags", items, { buffer = buf })
end

---@return boolean
function M.is_loading()
	return state.tags == "loading"
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "header"
end

return M
