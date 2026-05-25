---@class GHIssuesConversationTab : IssuesPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local helper = require("atlas.issues.ui.main.helper")
local md_editor = require("atlas.ui.popups.markdown_editor")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.issues.providers.github.ui.conversation.state")
local keymaps = require("atlas.issues.providers.github.ui.conversation.keymaps")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"
local EVENT_COLLAPSE_KEEP = 2
local EVENT_COLLAPSE_THRESHOLD = 5

local REACTION_EMOJI = {
	["+1"] = "👍", ["-1"] = "👎", laugh = "😄", hooray = "🎉",
	confused = "😕", heart = "❤️", rocket = "🚀", eyes = "👀",
}
local REACTION_KEYS = { "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }

---@param reactions table<string, number>|nil
---@return string
local function format_reactions(reactions)
	if type(reactions) ~= "table" then
		return ""
	end
	local parts = {}
	for _, key in ipairs(REACTION_KEYS) do
		local count = tonumber(reactions[key]) or 0
		if count > 0 then
			table.insert(parts, string.format("%s %d", REACTION_EMOJI[key] or key, count))
		end
	end
	if #parts == 0 then
		return ""
	end
	return table.concat(parts, "  ")
end

---@type { cancel: fun() }[]
local in_flight = {}

local function cancel_all()
	for _, h in ipairs(in_flight) do
		if h and h.cancel then
			pcall(h.cancel)
		end
	end
	in_flight = {}
end

---@param handle { cancel: fun() }|nil
local function track(handle)
	if handle then
		table.insert(in_flight, handle)
	end
end

---@return IssuesProvider|nil
local function get_provider()
	return require("atlas.issues.state").provider
end

---@param author IssueUser|nil
---@return string
local function author_name(author)
	if type(author) ~= "table" then
		return "Unknown"
	end
	if author.display_name and author.display_name ~= "" then
		return author.display_name
	end
	if author.account_id and author.account_id ~= "" then
		return author.account_id
	end
	return "Unknown"
end

---@param comment IssueComment
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.issues.state").current_user
	if not current_user or not comment.author then
		return false
	end
	return tostring(comment.author.account_id or "") == tostring(current_user.account_id or "")
end

--------------------------------------------------------------------------------
-- Timeline merge
--------------------------------------------------------------------------------

---@class GHConvEntry
---@field type "comment"|"event"|"event_gap"
---@field timestamp string
---@field comment IssueComment|nil
---@field event GHIssueTimelineEntry|nil
---@field count integer|nil

---@param entries GHConvEntry[]
---@param run GHConvEntry[]
local function append_event_run(entries, run)
	if #run <= EVENT_COLLAPSE_THRESHOLD then
		for _, entry in ipairs(run) do
			table.insert(entries, entry)
		end
		return
	end

	for i = 1, EVENT_COLLAPSE_KEEP do
		table.insert(entries, run[i])
	end
	table.insert(entries, {
		type = "event_gap",
		timestamp = run[EVENT_COLLAPSE_KEEP].timestamp,
		count = #run - (EVENT_COLLAPSE_KEEP * 2),
	})
	for i = #run - EVENT_COLLAPSE_KEEP + 1, #run do
		table.insert(entries, run[i])
	end
end

---@param entries GHConvEntry[]
---@return GHConvEntry[]
local function collapse_event_runs(entries)
	local collapsed = {}
	local run = {}

	for _, entry in ipairs(entries) do
		if entry.type == "event" then
			table.insert(run, entry)
		else
			append_event_run(collapsed, run)
			run = {}
			table.insert(collapsed, entry)
		end
	end
	append_event_run(collapsed, run)

	return collapsed
end

---@param comments IssueComment[]
---@param events GHIssueTimelineEntry[]
---@return GHConvEntry[]
local function build_conversation(comments, events)
	local entries = {}
	for _, c in ipairs(comments or {}) do
		table.insert(entries, { type = "comment", timestamp = c.created or "", comment = c })
	end
	for _, e in ipairs(events or {}) do
		table.insert(entries, { type = "event", timestamp = e.date or "", event = e })
	end
	table.sort(entries, function(a, b)
		return a.timestamp < b.timestamp
	end)
	return collapse_event_runs(entries)
end

--------------------------------------------------------------------------------
-- Comment box
--------------------------------------------------------------------------------

---@param comment IssueComment
---@param width integer
---@return string[], table[], table<integer, table>
local function render_comment(comment, width)
	local lines = {}
	local spans = {}
	local local_map = {}

	local author = author_name(comment.author)
	local author_hl = helper.person_hl(author)
	local time_text = utils.relative_time(comment.created)
	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)
	local icon = icons.general("user")

	local header_left = icon .. "  " .. author .. "  commented  " .. time_text
	local header_spans = {}
	local col = 0
	table.insert(header_spans, { line = 0, start_col = col, end_col = col + #icon, hl_group = author_hl })
	col = col + #icon + 2
	table.insert(header_spans, { line = 0, start_col = col, end_col = col + #author, hl_group = author_hl })
	col = col + #author + 2
	local commented_text = "commented  " .. time_text
	table.insert(header_spans, { line = 0, start_col = col, end_col = col + #commented_text, hl_group = "AtlasTextMuted" })

	local action_parts = { string.format("%s (c)", icons.general("reply")) }
	if is_own_comment(comment) then
		table.insert(action_parts, string.format("%s (e)", icons.general("edit")))
		table.insert(action_parts, string.format("%s (d)", icons.general("delete")))
	end
	local actions_text = table.concat(action_parts, "  ")

	local left_dw = vim.api.nvim_strwidth(header_left)
	local actions_dw = vim.api.nvim_strwidth(actions_text)
	local inner_content = box_inner - 2
	local gap = math.max(2, inner_content - left_dw - actions_dw)
	local header_line = header_left .. string.rep(" ", gap) .. actions_text
	local actions_byte_start = #header_left + gap
	table.insert(header_spans, {
		line = 0,
		start_col = actions_byte_start,
		end_col = actions_byte_start + #actions_text,
		hl_group = "AtlasTextMuted",
	})

	local content_lines = {}
	local content_spans = {}
	local raw = utils.strip_markup(tostring(comment.body or ""))
	if raw == "" then
		raw = "(empty comment)"
	end
	for _, line in ipairs(utils.sanitize_lines(raw)) do
		for _, chunk in ipairs(utils.wrap_line(line, box_inner)) do
			table.insert(content_lines, chunk)
		end
	end

	local reaction_text = format_reactions(comment.reactions)
	if reaction_text ~= "" then
		table.insert(content_lines, reaction_text)
		table.insert(content_spans, {
			line = #content_lines - 1,
			start_col = 0,
			end_col = #reaction_text,
			hl_group = "AtlasTextMuted",
		})
	end

	local groups = {
		{ lines = { header_line }, spans = header_spans },
		{ lines = content_lines, spans = content_spans },
	}
	local block = box.render(groups, { width = width, padding_x = PADDING_X })
	for _, l in ipairs(block.lines) do
		table.insert(lines, l)
	end
	for _, s in ipairs(block.highlights) do
		table.insert(spans, s)
	end

	local entry_data = { kind = "comment", comment = comment }
	for i = 1, #block.lines do
		local_map[i] = entry_data
	end

	return lines, spans, local_map
end

--------------------------------------------------------------------------------
-- Event line
--------------------------------------------------------------------------------

---@param event GHIssueTimelineEntry
---@return string label, string|nil hl_for_extra
local function event_label(event)
	local label, content = require("atlas.issues.providers.github.ui.event_label").format(event)
	if content and content ~= "" then
		return label .. ": " .. content, nil
	end
	return label, nil
end

local EVENT_ICON = {
	labeled = icons.pulls("activity"),
	unlabeled = icons.pulls("activity"),
	assigned = icons.general("user"),
	unassigned = icons.general("user"),
	milestoned = icons.pulls("activity"),
	demilestoned = icons.pulls("activity"),
	renamed = icons.general("edit"),
	closed = icons.pulls_status("successful"),
	reopened = icons.issues("issue"),
	locked = icons.pulls_status("stopped"),
	unlocked = icons.pulls_status("stopped"),
	pinned = icons.pulls("activity"),
	unpinned = icons.pulls("activity"),
	transferred = icons.pulls("activity"),
	marked_as_duplicate = icons.pulls("activity"),
	["cross-referenced"] = icons.pulls("activity"),
	referenced = icons.pulls("activity"),
}

---@param event GHIssueTimelineEntry
---@param width integer
---@return string[], table[]
local function render_event(event, width)
	local lines = {}
	local spans = {}
	local actor = author_name(event.actor)
	local label, _ = event_label(event)
	local time_text = utils.relative_time(event.date)
	local icon = EVENT_ICON[event.event] or icons.pulls("activity")

	local icon_prefix = icon .. "  "
	local icon_w = vim.api.nvim_strwidth(icon_prefix)
	local text = actor .. "  " .. label .. "  " .. time_text
	local content_width = math.max(10, width - PADDING_X - icon_w)
	local wrapped = utils.wrap_line(text, content_width)

	local first = PADDING .. icon_prefix .. wrapped[1]
	table.insert(lines, first)
	local first_len = #first
	local col = PADDING_X
	table.insert(spans, { line = 0, start_col = col, end_col = math.min(col + #icon, first_len), hl_group = "AtlasTextMuted" })
	col = col + #icon_prefix
	table.insert(spans, {
		line = 0,
		start_col = col,
		end_col = math.min(col + #actor, first_len),
		hl_group = helper.person_hl(actor),
	})
	col = col + #actor + 2
	if col < first_len then
		table.insert(spans, {
			line = 0,
			start_col = col,
			end_col = math.min(col + #label, first_len),
			hl_group = "AtlasTextMuted",
		})
		col = col + #label + 2
	end
	if col < first_len then
		table.insert(spans, {
			line = 0,
			start_col = col,
			end_col = math.min(col + #time_text, first_len),
			hl_group = "AtlasTextMuted",
		})
	end

	local cont = string.rep(" ", PADDING_X + icon_w)
	for i = 2, #wrapped do
		local ln = cont .. wrapped[i]
		table.insert(lines, ln)
		table.insert(spans, { line = #lines - 1, start_col = #cont, end_col = #ln, hl_group = "AtlasTextMuted" })
	end

	return lines, spans
end

---@param count integer
---@return string[], table[]
local function render_event_gap(count)
	local text = string.format(
		"%s  ... %d more %s",
		icons.general("activity_more"),
		count,
		count == 1 and "activity" or "activities"
	)
	local line = PADDING .. text
	return { line }, {
		{ line = 0, start_col = PADDING_X, end_col = PADDING_X + #text, hl_group = "AtlasTextMuted" },
	}
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	opts = opts or {}
	cancel_all()
	state.reset()
	state.issue = issue

	local key = tostring(issue.key or "")

	state.comments = "loading"
	state.timeline = "loading"

	footer.notify("loading", string.format("Loading conversation for %s...", key))

	local timeline_api = require("atlas.issues.providers.github.api.timeline")
	track(timeline_api.list_conversation(key, function(result, err)
		if err then
			state.comments = {}
			state.timeline = err
		else
			result = type(result) == "table" and result or {}
			state.comments = type(result.comments) == "table" and result.comments or {}
			state.timeline = type(result.events) == "table" and result.events or {}
		end
		refresh()
		if err then
			footer.notify("error", string.format("Failed to load conversation for %s", key), 1600)
		else
			footer.notify("success", string.format("Conversation loaded for %s", key), 1200)
		end
	end, { force_load = opts.force_refresh == true }))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

---@param issue Issue
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(issue, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.comments == nil and state.timeline == nil then
		return lines, spans, line_map
	end

	local comments_ready = type(state.comments) == "table"
	local timeline_ready = type(state.timeline) == "table"

	if not comments_ready and not timeline_ready then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local comments = comments_ready and state.comments or {}
	local timeline = timeline_ready and state.timeline or {}

	local entries = build_conversation(comments, timeline)
	if #entries == 0 then
		-- show issue body as the first comment-like box if present
		local raw = type(issue._raw) == "table" and issue._raw or {}
		if tostring(raw.body or "") ~= "" then
			-- intentionally fall through to render synthetic body comment below
		else
			utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
			return lines, spans, line_map
		end
	end

	local function add_connector()
		local cl = PADDING .. CONNECTOR
		table.insert(lines, cl)
		table.insert(spans, { line = #lines - 1, start_col = PADDING_X, end_col = PADDING_X + #CONNECTOR, hl_group = "AtlasBorder" })
	end

	-- Render the issue body as the first box (so the panel always has at least one box)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local body = tostring(raw.body or "")
	if body ~= "" then
		---@type IssueComment
		local body_comment = {
			id = "__body__",
			self = nil,
			url = issue.url,
			author = issue.reporter,
			body = body,
			_body = nil,
			created = raw.created_at or "",
			updated = nil,
			parent_id = nil,
			children = nil,
			reactions = raw.reactions,
		}
		local c_lines, c_spans, c_map = render_comment(body_comment, width)
		local offset = #lines
		for _, l in ipairs(c_lines) do
			table.insert(lines, l)
		end
		for _, s in ipairs(c_spans) do
			s.line = s.line + offset
			table.insert(spans, s)
		end
		for local_lnum, data in pairs(c_map) do
			line_map[offset + local_lnum] = data
		end
	end

	for i, entry in ipairs(entries) do
		if #lines > 0 then
			add_connector()
		end
		if entry.type == "comment" then
			local c_lines, c_spans, c_map = render_comment(entry.comment, width)
			local offset = #lines
			for _, l in ipairs(c_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(c_spans) do
				s.line = s.line + offset
				table.insert(spans, s)
			end
			for local_lnum, data in pairs(c_map) do
				line_map[offset + local_lnum] = data
			end
		elseif entry.type == "event_gap" then
			local e_lines, e_spans = render_event_gap(entry.count or 0)
			local offset = #lines
			for _, l in ipairs(e_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(e_spans) do
				s.line = s.line + offset
				table.insert(spans, s)
			end
		else
			local e_lines, e_spans = render_event(entry.event, width)
			local offset = #lines
			for _, l in ipairs(e_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(e_spans) do
				s.line = s.line + offset
				table.insert(spans, s)
			end
			line_map[offset + 1] = { kind = "event", event = entry.event }
		end
		if i == #entries then
			break
		end
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "comment" or entry.kind == "event"
end

---@param _issue Issue
---@param entry table
---@return boolean|nil
function M.on_enter(_issue, entry)
	if entry and entry.kind == "comment" then
		local url = entry.comment and entry.comment.url
		if url and url ~= "" then
			vim.ui.open(url)
			return true
		end
	end
	if entry and entry.kind == "event" and entry.event then
		if entry.event.commit_url and entry.event.commit_url ~= "" then
			vim.ui.open(entry.event.commit_url)
			return true
		end
		if entry.event.source_url and entry.event.source_url ~= "" then
			vim.ui.open(entry.event.source_url)
			return true
		end
	end
end

--------------------------------------------------------------------------------
-- Comment CRUD
--------------------------------------------------------------------------------

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.reply_comment(issue, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.reply_comment) ~= "function" then
		return
	end
	local comment = entry and entry.comment
	if not comment then
		return
	end

	local key = tostring(issue.key or "")
	local mention = comment.author and (comment.author.account_id or comment.author.display_name) or ""
	local initial_text = mention ~= "" and ("@" .. mention .. " ") or ""

	md_editor.open({
		key = "issue-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = initial_text,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Sending reply...")
			track(provider.reply_comment(key, tostring(comment.id), text, function(reply, err)
				if err then
					footer.notify("error", "Reply failed: " .. err)
					return
				end
				if type(reply) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, reply)
				end
				footer.notify("success", "Reply added", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param refresh fun()
function M.add_comment(issue, refresh)
	local provider = get_provider()
	if not provider or type(provider.add_comment) ~= "function" then
		return
	end
	local key = tostring(issue.key or "")
	md_editor.open({
		key = "issue-comment-add",
		title = " Add Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Adding comment...")
			track(provider.add_comment(key, text, function(comment, err)
				if err then
					footer.notify("error", "Add comment failed: " .. err)
					return
				end
				if type(comment) == "table" and type(state.comments) == "table" then
					table.insert(state.comments, comment)
				end
				footer.notify("success", "Comment added", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.edit_comment(issue, entry, refresh)
	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	if comment.id == "__body__" then
		M.edit_body(issue, refresh)
		return
	end

	local provider = get_provider()
	if not provider or type(provider.edit_comment) ~= "function" then
		return
	end
	local key = tostring(issue.key or "")
	md_editor.open({
		key = "issue-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = tostring(comment.body or ""),
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Editing comment...")
			track(provider.edit_comment(key, tostring(comment.id), text, function(updated, err)
				if err then
					footer.notify("error", "Edit failed: " .. err)
					return
				end
				if type(state.comments) == "table" then
					for i, c in ipairs(state.comments) do
						if tostring(c.id) == tostring(comment.id) then
							if type(updated) == "table" then
								state.comments[i] = updated
							else
								state.comments[i].body = text
							end
							break
						end
					end
				end
				footer.notify("success", "Comment updated", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param refresh fun()
function M.edit_body(issue, refresh)
	local raw = type(issue._raw) == "table" and issue._raw or {}
	local slug = tostring(raw.slug or "")
	local number = tonumber(raw.number)
	if slug == "" or number == nil then
		return
	end

	md_editor.open({
		key = "issue-body-edit-" .. tostring(issue.key),
		title = " Edit Issue ",
		width_ratio = 0.5,
		height_ratio = 0.4,
		initial_text = tostring(raw.body or ""),
		on_save = function(text)
			if text == nil then
				return
			end
			local cli = require("atlas.issues.providers.github.api.cli")
			footer.notify("loading", "Updating issue...")
			track(cli.gh({
				"issue", "edit", tostring(number), "--repo", slug, "--body", text,
			}, function(_, err)
				if err then
					footer.notify("error", "Edit failed: " .. tostring(err))
					return
				end
				raw.body = text
				cli.delete_cache(string.format("github_issues:get:%s#%d", slug, number))
				footer.notify("success", "Issue updated", 1200)
				refresh()
			end))
		end,
	})
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.add_reaction(issue, entry, refresh)
	local comment = entry and entry.comment
	if not comment then
		return
	end

	local raw = type(issue._raw) == "table" and issue._raw or {}
	local slug = tostring(raw.slug or "")
	local number = tonumber(raw.number)
	if slug == "" then
		return
	end

	local is_body = comment.id == "__body__"
	local endpoint
	if is_body then
		if number == nil then
			return
		end
		endpoint = string.format("repos/%s/issues/%d/reactions", slug, number)
	else
		endpoint = string.format("repos/%s/issues/comments/%s/reactions", slug, tostring(comment.id))
	end

	local choices = {}
	for _, key in ipairs(REACTION_KEYS) do
		table.insert(choices, { key = key, label = string.format("%s  %s", REACTION_EMOJI[key], key) })
	end

	vim.ui.select(choices, {
		prompt = "Add reaction",
		format_item = function(item)
			return item.label
		end,
	}, function(selected)
		if selected == nil then
			return
		end

		local cli = require("atlas.issues.providers.github.api.cli")
		footer.notify("loading", "Adding reaction...")
		track(cli.api("POST", endpoint, { content = selected.key }, function(_, err)
			if err then
				footer.notify("error", "Reaction failed: " .. tostring(err))
				return
			end

			if is_body then
				raw.reactions = raw.reactions or {}
				raw.reactions[selected.key] = (tonumber(raw.reactions[selected.key]) or 0) + 1
			elseif type(state.comments) == "table" then
				for _, c in ipairs(state.comments) do
					if tostring(c.id) == tostring(comment.id) then
						c.reactions = c.reactions or {}
						c.reactions[selected.key] = (tonumber(c.reactions[selected.key]) or 0) + 1
						break
					end
				end
			end

			footer.notify("success", string.format("Reacted with %s", REACTION_EMOJI[selected.key] or selected.key), 1200)
			refresh()
		end))
	end)
end

---@param issue Issue
---@param entry table
---@param refresh fun()
function M.delete_comment(issue, entry, refresh)
	local provider = get_provider()
	if not provider or type(provider.delete_comment) ~= "function" then
		return
	end
	local comment = entry.comment
	if not comment or comment.id == "__body__" or not is_own_comment(comment) then
		return
	end
	local key = tostring(issue.key or "")
	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		footer.notify("loading", "Deleting comment...")
		track(provider.delete_comment(key, tostring(comment.id), function(ok, err)
			if err then
				footer.notify("error", "Delete failed: " .. err)
				return
			end
			if ok and type(state.comments) == "table" then
				for i, c in ipairs(state.comments) do
					if tostring(c.id) == tostring(comment.id) then
						table.remove(state.comments, i)
						break
					end
				end
			end
			footer.notify("success", "Comment deleted", 1200)
			refresh()
		end))
	end)
end

--------------------------------------------------------------------------------
-- Activate / deactivate
--------------------------------------------------------------------------------

---@param buf integer|nil
---@param refresh fun()|nil
function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
		vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
	end
	keymaps.setup(buf, refresh)
end

---@param buf integer|nil
function M.deactivate(buf)
	if buf ~= nil then
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.treesitter.stop, buf)
			vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
			vim.api.nvim_set_option_value("filetype", "", { buf = buf })
		end
		keymaps.teardown(buf)
	end
	cancel_all()
end

return M
