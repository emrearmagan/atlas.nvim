local M = {}

local form = require("atlas.ui.form")
local issues = require("atlas.issues.providers.github.api.issues")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local users = require("atlas.providers.github.users")
local highlights = require("atlas.ui.highlights")
local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.issues.ui.presentation")

---@class GitHubIssueEditorValues
---@field title string
---@field body string
---@field labels string[]
---@field assignees string[]
---@field milestone integer|false

---@class GitHubIssueEditorState
---@field repo_slug string
---@field issue GitHubIssue|nil
---@field on_done (fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil))|nil
---@field labels IssueLabel[]
---@field assignees AtlasUser[]
---@field reporter AtlasUser|nil
---@field milestone GitHubIssueMilestone|nil
---@field initial GitHubIssueEditorValues
---@field requests AtlasRequestScope
---@field loading { labels?: boolean, assignees?: boolean, reporter?: boolean, milestone?: boolean }
---@field submitting boolean

---@param items table[]
---@param key string
---@return string[]
local function sorted_names(items, key)
	local result = {}
	for i, item in ipairs(items) do
		result[i] = item[key]
	end
	table.sort(result)
	return result
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
---@return GitHubIssueEditorValues
local function values(state, editor)
	local content = form.get_content(editor)
	return {
		title = vim.trim(content.title),
		body = content.body,
		labels = sorted_names(state.labels, "name"),
		assignees = sorted_names(state.assignees, "username"),
		milestone = state.milestone and state.milestone.number or false,
	}
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
---@return boolean
local function is_modified(state, editor)
	return not vim.deep_equal(values(state, editor), state.initial)
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function load_reporter(state, editor)
	local statusline = editor.statusline
	state.loading.reporter = true
	statusline:notify("loading", "Loading reporter...")
	form.render_meta(editor)

	state.requests.run(users.fetch_user, function(user, err)
		state.loading.reporter = nil
		state.reporter = user
		form.render_meta(editor)
		if state.submitting then
			return
		end
		if err or not user then
			statusline:notify("error", err or "Unable to load reporter")
			return
		end
		if statusline.loading_spinner then
			local pending = next(state.loading)
			if pending then
				statusline:notify("loading", "Loading " .. pending .. "...")
			else
				statusline:clear_notice()
			end
		end
	end)
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function select_assignees(state, editor)
	if state.submitting or state.loading.assignees then
		return
	end

	local statusline = editor.statusline
	state.loading.assignees = true
	statusline:notify("loading", "Loading assignees...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return users.get_assignable_users(state.repo_slug, nil, done)
	end, function(items, err)
		state.loading.assignees = nil
		form.render_meta(editor)
		if state.submitting then
			return
		end
		if err or not items then
			statusline:notify("error", err or "Unable to load assignees")
			return
		end
		if statusline.loading_spinner then
			local pending = next(state.loading)
			if pending then
				statusline:notify("loading", "Loading " .. pending .. "...")
			else
				statusline:clear_notice()
			end
		end
		picker.multi_select({
			title = "Assignees",
			items = items,
			selected = state.assignees,
			key = function(user)
				return user.username
			end,
			format_item = function(user)
				return "@" .. user.username .. " - " .. user.name
			end,
			on_done = function(selected)
				if not editor.closed and not state.submitting then
					state.assignees = selected
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function select_labels(state, editor)
	if state.submitting or state.loading.labels then
		return
	end

	local statusline = editor.statusline
	state.loading.labels = true
	statusline:notify("loading", "Loading labels...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.list_labels(state.repo_slug, done)
	end, function(items, err)
		state.loading.labels = nil
		form.render_meta(editor)
		if state.submitting then
			return
		end

		if err or not items then
			statusline:notify("error", err or "Unable to load labels")
			return
		end

		if statusline.loading_spinner then
			local pending = next(state.loading)
			if pending then
				statusline:notify("loading", "Loading " .. pending .. "...")
			else
				statusline:clear_notice()
			end
		end

		picker.multi_select({
			title = "Labels",
			items = items,
			selected = state.labels,
			key = function(label)
				return label.name
			end,
			format_item = function(label)
				return label.name
			end,
			on_done = function(selected)
				if not editor.closed and not state.submitting then
					state.labels = selected
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function select_milestone(state, editor)
	if state.submitting or state.loading.milestone then
		return
	end

	local statusline = editor.statusline
	state.loading.milestone = true
	statusline:notify("loading", "Loading milestone...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.list_milestones(state.repo_slug, done)
	end, function(items, err)
		state.loading.milestone = nil
		form.render_meta(editor)
		if state.submitting then
			return
		end

		if err or not items then
			statusline:notify("error", err or "Unable to load milestone")
			return
		end

		if statusline.loading_spinner then
			local pending = next(state.loading)
			if pending then
				statusline:notify("loading", "Loading " .. pending .. "...")
			else
				statusline:clear_notice()
			end
		end

		local none = { title = "None" }
		picker.select({
			title = "Milestone",
			items = vim.list_extend({ none }, items),
			format_item = function(item)
				return item.title
			end,
			on_select = function(selected)
				if selected and not editor.closed and not state.submitting then
					state.milestone = selected ~= none and selected or nil
					form.render_meta(editor)
				end
			end,
		})
	end)
end

---@param state GitHubIssueEditorState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local labels = { key = "Labels:", value = "None", hl = "AtlasTextMuted", loading = state.loading.labels }
	if #state.labels > 0 then
		labels.value = ""
		labels.spans = {}
		for _, label in ipairs(state.labels) do
			if labels.value ~= "" then
				labels.value = labels.value .. " "
			end
			local text = " " .. label.name .. " "
			local hl = highlights.chip(label.color)
			table.insert(labels.spans, { start_col = #labels.value, end_col = #labels.value + #text, hl_group = hl })
			labels.value = labels.value .. text
		end
	end

	local prefix = icons.general("user") .. " "
	local assignees = {
		key = "Assignees:",
		value = prefix .. "Unassigned",
		hl = "AtlasTextMuted",
		loading = state.loading.assignees,
	}
	if #state.assignees > 0 then
		assignees.value = prefix
		assignees.spans = {}
		for i, user in ipairs(state.assignees) do
			if i > 1 then
				assignees.value = assignees.value .. ", "
			end
			local text = "@" .. user.username
			table.insert(assignees.spans, {
				start_col = #assignees.value,
				end_col = #assignees.value + #text,
				hl_group = presentation.person_hl(user.username),
			})
			assignees.value = assignees.value .. text
		end
	end

	local reporter = state.reporter and state.reporter.username
	return {
		{
			{
				key = "Repo:",
				value = state.repo_slug,
				hl = highlights.dynamic_for(state.repo_slug:lower()),
			},
			{
				key = "Milestone:",
				value = state.milestone and state.milestone.title or "None",
				loading = state.loading.milestone,
				hl = state.milestone and "Normal" or "AtlasTextMuted",
			},
		},
		{
			assignees,
			{
				key = "Reporter:",
				value = prefix .. (reporter and "@" .. reporter or "Unknown"),
				hl = presentation.person_hl(reporter),
				loading = state.loading.reporter,
			},
		},
		{ labels },
	}
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end

	local current = values(state, editor)
	if current.title == "" then
		notify.warn("Title is required")
		return
	end

	if state.issue and not is_modified(state, editor) then
		form.close(editor)
		notify.info("No changes")
		return
	end

	state.submitting = true
	vim.bo[editor.editor_buf].modifiable = false
	editor.statusline:notify("loading", state.issue and "Saving issue..." or "Creating issue...")

	---@param result { number: integer|nil, url: string|nil }|nil
	---@param err string|nil
	local function done(result, err)
		editor.statusline:clear_notice()
		if not result then
			err = err or "Unable to save issue"
			state.submitting = false
			if not editor.closed then
				vim.bo[editor.editor_buf].modifiable = true
				editor.statusline:notify("error", err)
			else
				if state.on_done then
					state.on_done(nil, err)
				end
				notify.error(err)
			end
			return
		end

		local was_closed = editor.closed
		form.close(editor)
		state.submitting = false
		if state.on_done then
			state.on_done(result, nil)
		end

		local message = state.issue and "Issue updated" or "Issue created"
		if not state.issue and result.url then
			message = message .. ": " .. result.url
			pcall(vim.fn.setreg, "+", result.url)
		end

		notify.info(message, { vim_notify = true })
		if not state.issue and result.url and not was_closed then
			require("atlas.commands.open").open(result.url)
		end
	end

	if state.issue then
		issues.update_issue(state.issue.key, current, done)
		return
	end

	return issues.create_issue({
		repo_slug = state.repo_slug,
		title = current.title,
		body = current.body,
		labels = current.labels,
		assignees = current.assignees,
		milestone = state.milestone and state.milestone.title,
	}, done)
end

---@param state GitHubIssueEditorState
---@param editor AtlasForm
local function close(state, editor)
	if state.submitting then
		return
	elseif not is_modified(state, editor) then
		form.close(editor)
	else
		vim.ui.input({ prompt = "Discard issue changes? [y/N]: " }, function(answer)
			if not state.submitting and (answer or ""):lower() == "y" then
				form.close(editor)
			end
		end)
	end
end

---@param repo_slug string
---@param issue GitHubIssue|nil
---@param details GitHubIssueDetails|nil
---@param on_done (fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil))|nil
---@return AtlasForm
local function open_editor(repo_slug, issue, details, on_done)
	local labels = details and details.labels or {}
	local assignees = details and details.assignees or {}
	local milestone = details and details.milestone

	---@type GitHubIssueEditorState
	local state = {
		repo_slug = repo_slug,
		issue = issue,
		on_done = on_done,
		labels = labels,
		assignees = assignees,
		reporter = issue and issue.reporter,
		milestone = milestone,
		initial = {
			title = vim.trim(details and details.title or ""),
			body = details and details.description or "",
			labels = sorted_names(labels, "name"),
			assignees = sorted_names(assignees, "username"),
			milestone = milestone and milestone.number or false,
		},
		requests = requests.new(),
		loading = {},
		submitting = false,
	}

	local handle = form.open({
		header = issue and string.format("Edit issue #%d", issue.number) or "Create issue",
		initial_title = state.initial.title,
		initial_body = state.initial.body,
		completion = {
			context = { provider = "github", repository = repo_slug, issue = issue and { key = issue.key } },
		},
		is_modified = issue and function(editor)
			return is_modified(state, editor)
		end,
		meta = function()
			return render_meta(state)
		end,
		submit = function(editor)
			submit(state, editor)
		end,
		close = function(editor)
			close(state, editor)
		end,
		on_closed = function()
			state.requests.cancel()
			if not state.submitting and state.on_done then
				state.on_done(nil, nil)
			end
		end,
		keymaps = {
			{
				key = "ga",
				desc = "assignees",
				action = function(editor)
					select_assignees(state, editor)
				end,
			},
			{
				key = "gl",
				desc = "labels",
				action = function(editor)
					select_labels(state, editor)
				end,
			},
			{
				key = "gm",
				desc = "milestone",
				action = function(editor)
					select_milestone(state, editor)
				end,
			},
		},
	})

	if not issue then
		load_reporter(state, handle)
	end
	return handle
end

---@param repo_slug string
---@param on_done (fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil))|nil
---@return AtlasForm
function M.open(repo_slug, on_done)
	return open_editor(repo_slug, nil, nil, on_done)
end

---@param issue GitHubIssue
---@param on_done (fun(result: { number: integer|nil, url: string|nil }|nil, err: string|nil))|nil
---@return { cancel: fun() }|nil
function M.edit(issue, on_done)
	notify.loading("Loading " .. issue.key .. "...")
	return issues.get_issue(issue.key, function(details, err)
		if not details then
			err = err or "Unable to load issue"
			notify.error(err)
			if on_done then
				on_done(nil, err)
			end
			return
		end
		notify.clear()
		open_editor(issue.repo_full_name, issue, details, on_done)
	end, { force_refresh = true })
end

return M
