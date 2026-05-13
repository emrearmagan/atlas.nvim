---@class PullsCommitsTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local threads = require("atlas.ui.components.threadsv2")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.ui.panel.pr.tabs.commits.state")

local PADDING_X = 1
local MAX_STATUS_COMMITS = 5

---@type { cancel: fun() }[]
local in_flight = {}

---@return PullsProvider|nil
local function get_provider()
	local pulls_state = require("atlas.pulls.state")
	return pulls_state.provider
end

local function cancel_all()
	for _, handle in ipairs(in_flight) do
		handle.cancel()
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
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
	local content = author .. " · " .. when

	-- Build status
	local build_state = state.status_by_hash[commit.hash]
	if build_state == "loading" then
		content = content .. " · " .. icons.pulls_status("inprogress") .. " builds"
	elseif build_state ~= nil and build_state ~= "unknown" then
		content = content .. " · " .. icons.pulls_status(build_state) .. " " .. status_label(build_state)
	end

	-- Truncate message to leave room for hash + icon + gaps
	local icon_width = vim.api.nvim_strwidth(icons.pulls("commit")) + 1
	local hash_width = #hash + 2
	local max_msg = width - PADDING_X - icon_width - hash_width
	if max_msg > 0 and vim.api.nvim_strwidth(message) > max_msg then
		message = utils.truncate(message, max_msg, false)
	end

	return {
		icon = icons.pulls("commit"),
		icon_hl = "AtlasTextMuted",
		author = message,
		right_text = hash,
		content = content,
		meta = {
			build_state = build_state,
		},
		line_map = {
			commit = commit,
			build_url = state.url_by_hash[commit.hash],
		},
	}
end

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	opts = opts or {}

	local provider = get_provider()
	if not provider then
		return
	end

	local force_refresh = opts.force_refresh == true
	local should_fetch = force_refresh or state.commits == nil or state.commits == "loading" or type(state.commits) == "string"

	if should_fetch then
		cancel_all()
		state.reset()
	end

	if should_fetch and type(provider.fetch_commits) == "function" then
		local pr_id = tostring(pr.id or "")
		state.commits = "loading"
		footer.notify("loading", string.format("Loading commits for #%s...", pr_id))
		track(provider.fetch_commits(pr, opts, function(commits, err)
			if err then
				state.commits = err
				footer.notify("error", string.format("Failed to load commits for #%s", pr_id))
				refresh()
				return
			end

			state.commits = commits or {}
			footer.notify("success", string.format("Commits loaded for #%s", pr_id), 1200)

			-- Fetch build statuses for the first N commits
			if type(provider.fetch_commit_status) == "function" and type(state.commits) == "table" then
				local count = math.min(MAX_STATUS_COMMITS, #state.commits)
				for i = 1, count do
					local commit = state.commits[i]
					local hash = tostring(commit.hash or "")
					if hash ~= "" then
						state.status_by_hash[hash] = "loading"
						track(provider.fetch_commit_status(pr, commit, opts, function(status, url, status_err)
							if status_err then
								state.status_by_hash[hash] = "unknown"
							else
								state.status_by_hash[hash] = status or "unknown"
								state.url_by_hash[hash] = url
							end
							refresh()
						end))
					end
				end
			end

			refresh()
		end))
	end
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
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
			local build_state = type(item.meta) == "table" and tostring(item.meta.build_state or "") or ""

			if build_state ~= "" and build_state ~= "unknown" and build_state ~= "loading" then
				local marker = icons.pulls_status(build_state) .. " " .. status_label(build_state)
				local start_col, end_col = row:find(marker, 1, true)
				if start_col ~= nil and end_col ~= nil then
					table.insert(out, {
						start_col = start_col - 1,
						end_col = end_col,
						hl_group = status_hl(build_state),
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
	local url = entry.build_url
	if url and url ~= "" then
		vim.ui.open(url)
		return true
	end
end

function M.deactivate()
	cancel_all()
end

return M
