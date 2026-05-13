---@class GHConversationTab : PullsPanelTabModule
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local helper = require("atlas.pulls.ui.main.helper")
local core_utils = require("atlas.core.utils")
local md_editor = require("atlas.ui.popups.markdown_editor")
local footer = require("atlas.ui.components.footer")
local state = require("atlas.pulls.providers.github.ui.conversation.state")
local keymaps = require("atlas.pulls.providers.github.ui.conversation.keymaps")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"
local ACTIVITY_COLLAPSE_KEEP = 2
local ACTIVITY_COLLAPSE_THRESHOLD = 5

-- TODO: Consider nerd font icons for better terminal compatibility
local REACTION_EMOJI = {
	["+1"] = "👍",
	["-1"] = "👎",
	laugh = "😄",
	hooray = "🎉",
	confused = "😕",
	heart = "❤️",
	rocket = "🚀",
	eyes = "👀",
}

local REACTION_KEYS = { "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }

---@param reactions table|nil
---@return string
local function format_reactions(reactions)
	if type(reactions) ~= "table" then
		return ""
	end
	local parts = {}
	for _, key in ipairs(REACTION_KEYS) do
		local count = tonumber(reactions[key]) or 0
		if count > 0 then
			local emoji = REACTION_EMOJI[key] or key
			table.insert(parts, string.format("%s %d", emoji, count))
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

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---@param author {name: string, nickname: string|nil}|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.nickname and author.nickname ~= "" then
		return author.nickname
	end
	if author.name and author.name ~= "" then
		return author.name
	end
	return "Unknown"
end

---@param comment PullsComment
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.pulls.state").current_user
	if not current_user or not comment.author then
		return false
	end
	return comment.author.nickname == current_user.username or comment.author.name == current_user.name
end

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function get_completion(pr)
	local author_completion = require("atlas.pulls.providers.github.completion.author")

	local seen = {}
	local logins = {}

	local function add(login)
		local l = tostring(login or "")
		if l ~= "" and not seen[l] then
			seen[l] = true
			table.insert(logins, l)
		end
	end

	local raw = pr._raw or {}
	add(type(raw.author) == "table" and raw.author.login or (pr.author and pr.author.name))

	local reviews = type(raw.latestOpinionatedReviews) == "table" and raw.latestOpinionatedReviews.nodes or {}
	for _, r in ipairs(reviews) do
		add(type(r.author) == "table" and r.author.login or nil)
	end

	local comments = type(state.comments) == "table" and state.comments or {}
	for _, c in ipairs(comments) do
		add(c.author and c.author.nickname)
	end

	local activity = type(state.activity) == "table" and state.activity or {}
	for _, a in ipairs(activity) do
		if a.actor then
			add(a.actor.nickname or a.actor.name)
		end
	end

	if #logins == 0 then
		return nil
	end

	return author_completion.build_completion(logins)
end

local ACTIVITY_ICONS = {
	approval = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextWarning" },
	update = { icon = icons.pulls("activity"), hl = "AtlasTextMuted" },
}

---@param entry PullsActivityEntry
---@return string
local function activity_label(entry)
	local kind = entry.kind or ""
	if kind == "approval" then
		return "approved"
	elseif kind == "changes_requested" then
		return "requested changes"
	elseif kind == "review" then
		return "left a review"
	end
	return tostring(entry.content_raw or kind)
end

--------------------------------------------------------------------------------
-- Timeline
--------------------------------------------------------------------------------

---@class GHTimelineEntry
---@field type "comment"|"activity"|"activity_gap"
---@field timestamp string
---@field comment PullsComment|nil
---@field activity PullsActivityEntry|nil
---@field count integer|nil

---@param entries GHTimelineEntry[]
---@param run GHTimelineEntry[]
local function append_activity_run(entries, run)
	if #run <= ACTIVITY_COLLAPSE_THRESHOLD then
		for _, entry in ipairs(run) do
			table.insert(entries, entry)
		end
		return
	end

	for i = 1, ACTIVITY_COLLAPSE_KEEP do
		table.insert(entries, run[i])
	end
	table.insert(entries, {
		type = "activity_gap",
		timestamp = run[ACTIVITY_COLLAPSE_KEEP].timestamp,
		count = #run - (ACTIVITY_COLLAPSE_KEEP * 2),
	})
	for i = #run - ACTIVITY_COLLAPSE_KEEP + 1, #run do
		table.insert(entries, run[i])
	end
end

---@param entries GHTimelineEntry[]
---@return GHTimelineEntry[]
local function collapse_activity_runs(entries)
	local collapsed = {}
	local run = {}

	for _, entry in ipairs(entries) do
		if entry.type == "activity" then
			table.insert(run, entry)
		else
			append_activity_run(collapsed, run)
			run = {}
			table.insert(collapsed, entry)
		end
	end
	append_activity_run(collapsed, run)

	return collapsed
end

---@param comments PullsComment[]
---@param activity PullsActivityEntry[]
---@return GHTimelineEntry[]
local function build_timeline(comments, activity)
	local entries = {}

	for _, c in ipairs(comments) do
		table.insert(entries, {
			type = "comment",
			timestamp = c.created_on or "",
			comment = c,
		})
	end

	local function is_review_kind(kind)
		return kind == "approval" or kind == "changes_requested" or kind == "review"
	end

	for _, a in ipairs(activity) do
		if a.kind ~= "comment" then
			table.insert(entries, {
				type = "activity",
				timestamp = a.date or "",
				activity = a,
			})
			-- A review (approve / request-changes / plain commented review) with a top-level body renders as a comment block right after the activity row.
			if is_review_kind(a.kind) and type(a.content_raw) == "string" and a.content_raw ~= "" then
				table.insert(entries, {
					type = "comment",
					timestamp = a.date or "",
					comment = {
						id = "review-" .. tostring(a.date or ""),
						parent_id = nil,
						author = a.actor and {
							name = tostring(a.actor.name or a.actor.username or ""),
							nickname = tostring(a.actor.nickname or a.actor.username or ""),
							id = tostring(a.actor.id or ""),
						} or nil,
						content_raw = a.content_raw,
						created_on = a.date or "",
						inline = nil,
						inline_hunk = nil,
						is_task = nil,
						state = nil,
						url = nil,
						html_url = nil,
					},
				})
			end
		end
	end

	table.sort(entries, function(a, b)
		return a.timestamp < b.timestamp
	end)

	return collapse_activity_runs(entries)
end

--------------------------------------------------------------------------------
-- Render box
--------------------------------------------------------------------------------

---@param comment PullsComment
---@param width integer
---@return string[], table[], table<integer, table>
local function render_comment(comment, width)
	local lines = {}
	local spans = {}
	local line_map_entries = {}

	local author = author_name(comment.author)
	local author_hl = helper.author_hl(author)
	local time_text = utils.relative_time(comment.created_on)
	local is_deleted = comment.deleted == true

	-- Header group
	local icon = icons.general("user")
	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)

	local header_left = icon .. "  " .. author .. "  commented  " .. time_text
	local header_spans = {}
	local col = 0
	table.insert(header_spans, { line = 0, start_col = col, end_col = col + #icon, hl_group = author_hl })
	col = col + #icon + 2
	table.insert(header_spans, { line = 0, start_col = col, end_col = col + #author, hl_group = author_hl })
	col = col + #author + 2
	local commented_text = "commented  " .. time_text
	table.insert(
		header_spans,
		{ line = 0, start_col = col, end_col = col + #commented_text, hl_group = "AtlasTextMuted" }
	)

	local action_parts = { string.format("%s (c)", icons.general("reply")) }
	if not is_deleted and is_own_comment(comment) then
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

	-- Content group
	local content_lines = {}
	local content_spans = {}

	if is_deleted then
		table.insert(content_lines, "(deleted comment)")
		table.insert(content_spans, {
			line = 0,
			start_col = 0,
			end_col = #"(deleted comment)",
			hl_group = "AtlasTextMutedItalic",
		})
	else
		local raw = utils.strip_markup(comment.content_raw or "")
		if raw == "" then
			raw = "(empty comment)"
		end
		local sanitized = utils.sanitize_lines(raw)
		for _, line in ipairs(sanitized) do
			local wrapped = utils.wrap_line(line, box_inner)
			for _, chunk in ipairs(wrapped) do
				table.insert(content_lines, chunk)
			end
		end
	end

	local reaction_text = format_reactions(comment.reactions)
	if reaction_text ~= "" then
		table.insert(content_lines, reaction_text)
		table.insert(
			content_spans,
			{ line = #content_lines - 1, start_col = 0, end_col = #reaction_text, hl_group = "AtlasTextMuted" }
		)
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

	local entry_data = { kind = "comment", comment = comment, entity_kind = "comment" }
	for i = 1, #block.lines do
		line_map_entries[i] = entry_data
	end

	return lines, spans, line_map_entries
end

--------------------------------------------------------------------------------
-- Render: activity line
--------------------------------------------------------------------------------

---@param entry PullsActivityEntry
---@param width integer
---@return string[], table[]
local function render_activity(entry, width)
	local lines = {}
	local spans = {}

	local kind = entry.kind or "update"
	local ai = ACTIVITY_ICONS[kind] or ACTIVITY_ICONS.update
	local actor = author_name(entry.actor)
	local label = activity_label(entry)
	local time_text = utils.relative_time(entry.date)

	local icon_prefix = ai.icon .. "  "
	local icon_width = vim.api.nvim_strwidth(icon_prefix)
	local text = actor .. "  " .. label .. "  " .. time_text
	local content_width = math.max(10, width - PADDING_X - icon_width)
	local wrapped = utils.wrap_line(text, content_width)

	-- First line with icon
	local first_line = PADDING .. icon_prefix .. wrapped[1]
	table.insert(lines, first_line)
	local line_len = #first_line
	local col = PADDING_X
	table.insert(spans, { line = 0, start_col = col, end_col = math.min(col + #ai.icon, line_len), hl_group = ai.hl })
	col = col + #icon_prefix
	table.insert(
		spans,
		{ line = 0, start_col = col, end_col = math.min(col + #actor, line_len), hl_group = helper.author_hl(actor) }
	)
	col = col + #actor + 2
	if col < line_len then
		table.insert(
			spans,
			{ line = 0, start_col = col, end_col = math.min(col + #label, line_len), hl_group = "AtlasTextMuted" }
		)
		col = col + #label + 2
	end
	if col < line_len then
		table.insert(
			spans,
			{ line = 0, start_col = col, end_col = math.min(col + #time_text, line_len), hl_group = "AtlasTextMuted" }
		)
	end

	-- Continuation lines aligned after icon
	local continuation = string.rep(" ", PADDING_X + icon_width)
	for i = 2, #wrapped do
		local cont_line = continuation .. wrapped[i]
		table.insert(lines, cont_line)
		table.insert(
			spans,
			{ line = #lines - 1, start_col = PADDING_X + icon_width, end_col = #cont_line, hl_group = "AtlasTextMuted" }
		)
	end

	return lines, spans
end

---@param count integer
---@return string[], table[]
local function render_activity_gap(count)
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

---@param pr PullRequest
---@param repo PullsRepo|nil
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, repo, refresh, opts)
	cancel_all()
	state.reset()

	local pr_id = tostring(pr.id or "")
	local activity_api = require("atlas.pulls.providers.github.api.activity")
	local pullrequests = require("atlas.pulls.providers.github.api.pullrequests")

	state.comments = "loading"
	state.activity = "loading"
	footer.notify("loading", string.format("Loading conversation for #%s...", pr_id))
	track(activity_api.fetch_conversation(pr, opts, function(result, err)
		if err then
			state.comments = err
			state.activity = err
			footer.notify("error", string.format("Failed to load conversation for #%s", pr_id))
		else
			result = type(result) == "table" and result or {}
			state.comments = type(result.comments) == "table" and result.comments or {}
			state.activity = type(result.events) == "table" and result.events or {}
			footer.notify("success", string.format("Conversation loaded for #%s", pr_id), 1200)
		end
		refresh()
	end))

	state.description = "loading"
	track(pullrequests.get_description(pr, opts, function(desc, err)
		state.description = err and "" or (desc or "")
		refresh()
	end))
end

--------------------------------------------------------------------------------
-- Render
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	local comments_ready = type(state.comments) == "table"
	local activity_ready = type(state.activity) == "table"

	if state.comments == nil and state.activity == nil then
		return lines, spans, line_map
	end

	if not comments_ready and not activity_ready then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local comments = comments_ready and state.comments or {}
	local activity = activity_ready and state.activity or {}

	local timeline = build_timeline(comments, activity)
	local body = ""
	if type(state.description) == "string" and state.description ~= "loading" then
		body = state.description
	elseif state.description == nil then
		body = tostring(pr.description or "")
	end

	if #timeline == 0 and body == "" then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local function add_connector()
		local connector_line = PADDING .. CONNECTOR
		table.insert(lines, connector_line)
		table.insert(spans, {
			line = #lines - 1,
			start_col = PADDING_X,
			end_col = PADDING_X + #CONNECTOR,
			hl_group = "AtlasBorder",
		})
	end

	if body ~= "" then
		---@type PullsComment
		local body_comment = {
			id = "__body__",
			parent_id = nil,
			author = pr.author and {
				name = pr.author.name or pr.author.username or "",
				nickname = pr.author.nickname or pr.author.username or pr.author.name or "",
				id = pr.author.id or "",
			} or nil,
			content_raw = body,
			created_on = pr.created_on or "",
			deleted = false,
			inline = nil,
			url = pr.link and pr.link.html or nil,
			html_url = pr.link and pr.link.html or nil,
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

	for _, entry in ipairs(timeline) do
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
		elseif entry.type == "activity" then
			local a_lines, a_spans = render_activity(entry.activity, width)
			local offset = #lines
			for _, l in ipairs(a_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(a_spans) do
				s.line = s.line + offset
				table.insert(spans, s)
			end
			line_map[offset + 1] = { kind = "activity", activity = entry.activity }
		elseif entry.type == "activity_gap" then
			local g_lines, g_spans = render_activity_gap(entry.count or 0)
			local offset = #lines
			for _, l in ipairs(g_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(g_spans) do
				s.line = s.line + offset
				table.insert(spans, s)
			end
		end
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "comment" or entry.kind == "activity"
end

function M.activate(buf, refresh)
	if buf == nil or refresh == nil then
		return
	end
	keymaps.setup(buf, refresh)
end

function M.deactivate(buf)
	if buf ~= nil then
		keymaps.teardown(buf)
	end
	cancel_all()
end

--------------------------------------------------------------------------------
-- Comment CRUD
--------------------------------------------------------------------------------

---@param pr PullRequest
---@param refresh fun()
function M.add_comment(pr, refresh)
	local comments_api = require("atlas.pulls.providers.github.api.comments")

	local completion = get_completion(pr)
	md_editor.open({
		key = "pr-comment-add",
		title = " Add Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		completion = completion,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Adding comment...")
			track(comments_api.add_comment(pr, text, nil, function(comment, err)
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.reply_comment(pr, entry, refresh)
	local comments_api = require("atlas.pulls.providers.github.api.comments")
	local comment = entry.comment
	if not comment then
		return
	end

	local completion = get_completion(pr)
	local author = comment.author or {}
	local mention = tostring(author.nickname or author.name or "")
	local initial_text = mention ~= "" and ("@" .. mention .. " ") or ""
	md_editor.open({
		key = "pr-comment-reply-" .. tostring(comment.id),
		title = " Reply to Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = initial_text,
		completion = completion,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Sending reply...")
			track(comments_api.add_comment(pr, text, { parent = comment }, function(reply, err)
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

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.edit_comment(pr, entry, refresh)
	local comments_api = require("atlas.pulls.providers.github.api.comments")
	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	local completion = get_completion(pr)
	md_editor.open({
		key = "pr-comment-edit-" .. tostring(comment.id),
		title = " Edit Comment ",
		width_ratio = 0.5,
		height_ratio = 0.18,
		initial_text = comment.content_raw or "",
		completion = completion,
		on_save = function(text)
			if not text or vim.trim(text) == "" then
				return
			end
			footer.notify("loading", "Editing comment...")
			local updated = vim.tbl_extend("force", {}, comment, { content_raw = text })
			track(comments_api.edit_comment(pr, updated, function(_, err)
				if err then
					footer.notify("error", "Edit failed: " .. err)
					return
				end
				local comments = core_utils.as_table(state.comments) or {}
				for i, c in ipairs(comments) do
					if c.id == comment.id then
						comments[i].content_raw = text
						break
					end
				end
				footer.notify("success", "Comment updated", 1200)
				refresh()
			end))
		end,
	})
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.delete_comment(pr, entry, refresh)
	local comments_api = require("atlas.pulls.providers.github.api.comments")
	local comment = entry.comment
	if not comment or not is_own_comment(comment) then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		footer.notify("loading", "Deleting comment...")
		track(comments_api.delete_comment(pr, comment, function(ok, err)
			if err then
				footer.notify("error", "Delete failed: " .. err)
				return
			end
			if ok then
				local comments = core_utils.as_table(state.comments) or {}
				for i, c in ipairs(comments) do
					if c.id == comment.id then
						table.remove(comments, i)
						break
					end
				end
			end
			footer.notify("success", "Comment deleted", 1200)
			refresh()
		end))
	end)
end

---@param pr PullRequest
---@param entry table
---@param refresh fun()
function M.add_reaction(pr, entry, refresh)
	local comment = entry and entry.comment
	if not comment then
		return
	end

	local repo_slug = pr.repo_full_name or ""
	if repo_slug == "" then
		return
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

		local cli = require("atlas.pulls.providers.github.api.cli")
		footer.notify("loading", "Adding reaction...")
		track(cli.api("POST", string.format("repos/%s/issues/comments/%s/reactions", repo_slug, tostring(comment.id)), {
			content = selected.key,
		}, function(_, err)
			if err then
				footer.notify("error", "Reaction failed: " .. tostring(err))
				return
			end

			local comments = core_utils.as_table(state.comments) or {}
			for _, c in ipairs(comments) do
				if c.id == comment.id and type(c.reactions) == "table" then
					c.reactions[selected.key] = (tonumber(c.reactions[selected.key]) or 0) + 1
					break
				end
			end

			footer.notify(
				"success",
				string.format("Reacted with %s", REACTION_EMOJI[selected.key] or selected.key),
				1200
			)
			refresh()
		end))
	end)
end

return M
