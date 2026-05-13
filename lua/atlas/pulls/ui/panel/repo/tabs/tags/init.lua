---@class PullsRepoTagsTab : PullsRepoPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local footer = require("atlas.ui.components.footer")
local threads = require("atlas.ui.components.threadsv2")
local state = require("atlas.pulls.ui.panel.repo.tabs.tags.state")
local repo_panel_state = require("atlas.pulls.ui.panel.repo.state")

local PADDING_X = 1

---@type { cancel: fun() }|nil
local request = nil

local function stop_request()
	if request ~= nil then
		request.cancel()
		request = nil
	end
end

---@param repo PullsRepoDetails
---@return AtlasThreadV2Item[]
local function to_items(repo)
	local items = {}
	for _, tag in ipairs((state.tags or {}).entries or {}) do
		local first_line = tag.message and tostring(tag.message:match("^[^\n\r]*") or "") or nil
		if first_line == "" then first_line = nil end
		local author_str = tag.author and tostring(tag.author) or nil
		if author_str == "" then author_str = nil end
		local content = nil
		if author_str and first_line then
			content = author_str .. " · " .. first_line
		elseif first_line then
			content = first_line
		elseif author_str then
			content = author_str
		end
		table.insert(items, {
			icon = icons.pulls("tag"),
			author = tostring(tag.name or ""),
			additional = tag.hash and tostring(tag.hash):sub(1, 8) or nil,
			right_text = tag.date and utils.relative_time_text(tag.date) or nil,
			content = content,
			obj = { repo = repo, tag = tag },
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

	if state.tags == nil then
		if repo_panel_state.current_repo_details == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
		end
		return lines, spans, line_map
	end

	if state.tags == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading tags..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local repo = state.repo
	if repo == nil then
		utils.push(lines, spans, "No tags loaded.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local entries = state.tags.entries or {}
	if #entries == 0 then
		utils.push(lines, spans, "No tags found.", "AtlasTextMuted", PADDING_X)
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
		state.tags = "loading"
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
	local should_fetch = opts.force_refresh == true or state.tags == nil or state.tags == "loading" or prev_name ~= next_name
	state.repo = detail
	if not should_fetch then
		refresh()
		return
	end

	stop_request()
	state.tags = "loading"
	footer.notify("loading", string.format("Loading tags for %s...", repo_label))
	refresh()

	local provider = require("atlas.pulls.state").provider
	if provider == nil or type(provider.fetch_repo_tags) ~= "function" then
		state.tags = { entries = {} }
		footer.notify("error", "Tag listing is not supported by this provider")
		refresh()
		return
	end

	request = provider.fetch_repo_tags(detail, {
		force_load = opts.force_load == true or opts.force_refresh == true,
		pagelen = opts.pagelen,
	}, function(tags, err)
		request = nil
		local active_detail = require("atlas.pulls.ui.panel.repo.state").current_repo_details
		if type(active_detail) ~= "table" or tostring(active_detail.full_name or "") ~= next_name then
			return
		end
		state.repo = active_detail
		if err then
			state.tags = { entries = {} }
			footer.notify("error", string.format("Failed to load tags for %s", repo_label))
		else
			state.tags = tags or { entries = {} }
			footer.notify("success", string.format("Tags loaded for %s", repo_label), 1200)
		end
		refresh()
	end)
end

function M.deactivate()
	stop_request()
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
