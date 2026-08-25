local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local MAX_STATUS_COMMITS = 5

---@class PullsCommitsTabState
---@field current_pr PullRequest|nil
---@field commits PullsCommit[]|"loading"|string|nil
---@field status_by_hash table<string, string>
---@field url_by_hash table<string, string>
---@field requests AtlasRequestScope
local state = {
	current_pr = nil,
	commits = nil,
	status_by_hash = {},
	url_by_hash = {},
	requests = request_scope.new(),
}

local function reset_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

function M.reset()
	reset_requests()
	state.current_pr = nil
	state.commits = nil
	state.status_by_hash = {}
	state.url_by_hash = {}
end

---@param pr PullRequest
---@return boolean
local function is_current(pr)
	return state.current_pr ~= nil
		and tostring(state.current_pr.id or "") == tostring(pr.id or "")
		and tostring(state.current_pr.repo_full_name or "") == tostring(pr.repo_full_name or "")
end

---@param state_name string|nil
---@return string
local function status_hl(state_name)
	if state_name == "successful" then
		return "AtlasTextPositive"
	end
	if state_name == "failed" then
		return "AtlasLogError"
	end
	if state_name == "inprogress" then
		return "AtlasTextWarning"
	end
	return "AtlasTextMuted"
end

---@param status string
---@return string
local function status_label(status)
	local s = tostring(status or ""):lower()
	if s == "" then
		return "Unknown"
	end
	return s:sub(1, 1):upper() .. s:sub(2)
end

---@param commit PullsCommit
---@param width integer
---@return AtlasThreadV2Item
local function to_thread_item(commit, width)
	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	message = message:match("([^\n]+)") or message

	local author = (commit.author_nickname ~= "" and commit.author_nickname) or commit.author_name or "Unknown"
	local hash = tostring(commit.short_hash or commit.hash or ""):sub(1, 8)
	local when = utils.relative_time(commit.date)
	local content = author .. "  " .. when

	-- Pipeline status
	local pipeline_state = state.status_by_hash[commit.hash]
	if pipeline_state == "loading" then
		content = content .. "  " .. icons.pulls_status("inprogress") .. " pipelines"
	elseif pipeline_state ~= nil and pipeline_state ~= "unknown" then
		content = content .. "  " .. icons.pulls_status(pipeline_state) .. " " .. status_label(pipeline_state)
	end

	-- Truncate message to leave room for hash + icon + gaps
	local commit_icon, commit_icon_hl = icons.pulls("commit")
	local icon_width = vim.api.nvim_strwidth(commit_icon) + 1
	local hash_width = #hash + 2
	local max_msg = width - PADDING_X - icon_width - hash_width
	if max_msg > 0 and vim.api.nvim_strwidth(message) > max_msg then
		message = utils.truncate(message, max_msg, false)
	end

	return {
		icon = commit_icon,
		icon_hl = commit_icon_hl,
		author = message,
		right_text = hash,
		content = content,
		meta = {
			pipeline_state = pipeline_state,
		},
		line_map = {
			commit = commit,
			pipeline_url = state.url_by_hash[commit.hash],
		},
	}
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}

	local provider = detail.provider
	if not provider then
		return
	end
	local core = provider.capabilities.core
	local pipelines = provider.capabilities.pipelines

	local force_refresh = opts.force_refresh == true
	local should_fetch = force_refresh
		or not is_current(pr)
		or state.commits == nil
		or state.commits == "loading"
		or type(state.commits) == "string"

	if not should_fetch or not core.fetch_commits then
		return
	end

	M.reset()
	state.current_pr = pr
	local pr_id = tostring(pr.id or "")
	state.commits = "loading"
	notify.loading(string.format("Loading commits for #%s...", pr_id))
	state.requests.run(function(done)
		return core.fetch_commits(pr, opts, done)
	end, function(commits, err)
		if not is_current(pr) then
			return
		end
		if err then
			state.commits = tostring(err)
			notify.error(string.format("Failed to load commits for #%s", pr_id))
			refresh()
			return
		end

		state.commits = commits or {}
		notify.success(string.format("Commits loaded for #%s", pr_id), { timeout = 1200 })

		-- Fetch pipeline statuses for the first N commits
		if pipelines and pipelines.fetch_commit_status and type(state.commits) == "table" then
			local count = math.min(MAX_STATUS_COMMITS, #state.commits)
			for i = 1, count do
				local commit = state.commits[i]
				local hash = tostring(commit.hash or "")
				if hash ~= "" then
					state.status_by_hash[hash] = "loading"
					state.requests.run(function(done)
						return pipelines.fetch_commit_status(commit, opts, done)
					end, function(status, url, status_err)
						if not is_current(pr) then
							return
						end
						if status_err then
							state.status_by_hash[hash] = "unknown"
						else
							state.status_by_hash[hash] = status or "unknown"
							state.url_by_hash[hash] = url
						end
						refresh()
					end)
				end
			end
		end

		refresh()
	end)
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, _details, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.commits == nil then
		return lines, spans, line_map
	end

	-- Loading
	if state.commits == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading commits..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	-- Error
	if type(state.commits) == "string" then
		utils.push(lines, spans, state.commits, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	-- Empty
	local entries = state.commits
	if #entries == 0 then
		utils.push(lines, spans, "No commits yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	-- Thread items
	local items = {}
	for _, commit in ipairs(entries) do
		table.insert(items, to_thread_item(commit, width))
	end

	local thread_lines, thread_spans, thread_map = threads.render(items, width, {
		padding_x = PADDING_X,
		mode = "linked",
		author_hl = function()
			return "AtlasText"
		end,
		content_hl = function(item, row, _)
			local out = { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
			local pipeline_state = item.meta and tostring(item.meta.pipeline_state or "") or ""

			if pipeline_state ~= "" and pipeline_state ~= "unknown" and pipeline_state ~= "loading" then
				local marker = icons.pulls_status(pipeline_state) .. " " .. status_label(pipeline_state)
				local start_col, end_col = row:find(marker, 1, true)
				if start_col ~= nil and end_col ~= nil then
					table.insert(out, {
						start_col = start_col - 1,
						end_col = end_col,
						hl_group = status_hl(pipeline_state),
					})
				end
			end
			return out
		end,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = thread_lines, highlights = thread_spans })
	for lnum, entry in pairs(thread_map or {}) do
		line_map[offset + lnum] = entry
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "header"
end

---@param _pr PullRequest
---@param entry table
---@return boolean|nil
function M.on_enter(_pr, entry)
	local url = entry.pipeline_url
	if url and url ~= "" then
		vim.ui.open(url)
		return true
	end
end

---@return boolean
function M.is_loading()
	if state.commits == "loading" then
		return true
	end
	for _, status in pairs(state.status_by_hash) do
		if status == "loading" then
			return true
		end
	end
	return false
end

function M.deactivate()
	M.reset()
	notify.clear()
end

return M
