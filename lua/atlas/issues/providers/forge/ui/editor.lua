local M = {}

local form = require("atlas.ui.form")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local highlights = require("atlas.ui.highlights")
local icons = require("atlas.ui.shared.icons")
local request_scope = require("atlas.core.requests")

---@class ForgeIssueEditorOpts
---@field repo_slug string
---@field issue GiteaIssue|ForgejoIssue|nil
---@field details GiteaIssueDetails|ForgejoIssueDetails|nil
---@field on_done fun(result: ForgeIssueCreateResult|nil, err: string|nil)|nil

---@class ForgeIssueEditor
---@field open fun(repo_slug: string, on_done: fun(result: ForgeIssueCreateResult|nil, err: string|nil)|nil): AtlasForm
---@field edit fun(issue: GiteaIssue|ForgejoIssue, on_done: fun(result: ForgeIssueCreateResult|nil, err: string|nil)|nil): ForgeRequestHandle|nil

---@class ForgeIssueEditorState
---@field fields { repo_slug: string, labels: (GiteaIssueLabel|ForgejoIssueLabel)[], assignees: AtlasUser[], milestone: GiteaIssueMilestone|ForgejoIssueMilestone|nil, due_date: string|nil }
---@field issue GiteaIssue|ForgejoIssue|nil
---@field provider_name "Gitea"|"Forgejo"
---@field api ForgeIssuesApi
---@field users AtlasUsersCapability
---@field initial table
---@field layout AtlasForm
---@field is_submitting boolean
---@field closed boolean
---@field completed boolean
---@field requests AtlasRequestScope
---@field on_done fun(result: ForgeIssueCreateResult|nil, err: string|nil)|nil

---@param values (GiteaIssueLabel|ForgejoIssueLabel)[]
---@return AtlasFormMetaField
local function labels_cell(values)
	if #values == 0 then
		return { key = "Labels:", value = "None", hl = "AtlasTextMuted" }
	end
	local pieces, spans = {}, {}
	local cursor = 0
	for _, label in ipairs(values) do
		local name = label.name
		if name ~= "" then
			if #pieces > 0 then
				table.insert(pieces, " ")
				cursor = cursor + 1
			end
			local chip = " " .. name .. " "
			table.insert(pieces, chip)
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #chip,
				hl_group = highlights.chip(label.color),
			})
			cursor = cursor + #chip
		end
	end
	return { key = "Labels:", value = table.concat(pieces), spans = spans }
end

---@param state ForgeIssueEditorState
---@return AtlasFormMetaRow[]
local function meta_rows(state)
	local assignees = {}
	for _, user in ipairs(state.fields.assignees) do
		table.insert(assignees, "@" .. user.username)
	end
	local assignee_text = #assignees > 0 and table.concat(assignees, ", ") or "Unassigned"
	local milestone = state.fields.milestone and state.fields.milestone.title or "None"
	local due_date = state.fields.due_date or "None"
	return {
		{
			{
				key = "Repo:",
				value = state.fields.repo_slug,
				hl = highlights.dynamic_for(state.fields.repo_slug:lower()),
			},
			{ key = "Milestone:", value = milestone, hl = state.fields.milestone and "Normal" or "AtlasTextMuted" },
		},
		{
			{ key = "Assignees:", value = assignee_text, hl = #assignees > 0 and "Normal" or "AtlasTextMuted" },
			{ key = "Due:", value = due_date, hl = state.fields.due_date and "AtlasTextWarning" or "AtlasTextMuted" },
		},
		{ labels_cell(state.fields.labels) },
	}
end

---@param state ForgeIssueEditorState
local function render_meta(state)
	form.render_meta(state.layout)
end

---@param state ForgeIssueEditorState
---@param result ForgeIssueCreateResult|nil
---@param err string|nil
local function complete(state, result, err)
	if state.completed then
		return
	end
	state.completed = true
	if state.on_done then
		state.on_done(result, err)
	end
end

---@param state ForgeIssueEditorState
---@param cancelled boolean|nil
local function close(state, cancelled)
	if state.closed then
		return
	end
	state.closed = true
	state.requests.cancel()
	form.close(state.layout)
	state.is_submitting = false
	if cancelled then
		complete(state, nil, nil)
	end
end

---@param state ForgeIssueEditorState
---@param content { title: string, body: string }|nil
---@return table
local function values(state, content)
	content = content or form.get_content(state.layout)
	local labels, assignees = {}, {}
	for _, label in ipairs(state.fields.labels) do
		labels[#labels + 1] = label.id
	end
	for _, user in ipairs(state.fields.assignees) do
		assignees[#assignees + 1] = user.username
	end
	table.sort(labels)
	table.sort(assignees)
	return {
		title = vim.trim(content.title),
		body = content.body,
		labels = labels,
		assignees = assignees,
		milestone = state.fields.milestone and state.fields.milestone.id or false,
		due_date = state.fields.due_date or false,
	}
end

---@param state ForgeIssueEditorState
---@return boolean
local function is_modified(state)
	return not vim.deep_equal(values(state), state.initial)
end

---@param state ForgeIssueEditorState
local function confirm_close(state)
	if state.closed or state.is_submitting then
		return
	end
	if not is_modified(state) then
		close(state, true)
		return
	end
	vim.ui.input({ prompt = "Discard issue changes? [y/N]: " }, function(input)
		if not state.closed and not state.is_submitting and vim.trim(tostring(input or "")):lower() == "y" then
			close(state, true)
		end
	end)
end

---@param state ForgeIssueEditorState
local function pick_assignees(state)
	if state.closed or state.is_submitting then
		return
	end
	state.layout.statusline:notify("loading", "Loading assignees...")
	state.requests.run(function(done)
		return state.users.get_assignable_users(state.fields.repo_slug, nil, done)
	end, function(items, err)
		if state.is_submitting then
			return
		end
		if err or not items then
			state.layout.statusline:notify("error", err or "Failed to load assignees")
			return
		end
		state.layout.statusline:clear_notice()
		picker.multi_select({
			items = items,
			selected = state.fields.assignees,
			key = function(item)
				return item.username
			end,
			format_item = function(item)
				return string.format("%s %s (@%s)", icons.get("user"), item.name, item.username)
			end,
			title = "Assignees",
			on_done = function(selected)
				if state.closed or state.is_submitting then
					return
				end
				state.fields.assignees = selected
				render_meta(state)
			end,
		})
	end)
end

---@param state ForgeIssueEditorState
local function pick_labels(state)
	if state.closed or state.is_submitting then
		return
	end
	state.layout.statusline:notify("loading", "Loading labels...")
	state.requests.run(function(done)
		return state.api.list_labels(state.fields.repo_slug, done)
	end, function(items, err)
		if state.is_submitting then
			return
		end
		if err or not items then
			state.layout.statusline:notify("error", err or "Failed to load labels")
			return
		end
		state.layout.statusline:clear_notice()
		picker.multi_select({
			items = items,
			selected = state.fields.labels,
			key = function(item)
				return tostring(item.id)
			end,
			format_item = function(item)
				return item.name
			end,
			title = "Labels",
			on_done = function(selected)
				if state.closed or state.is_submitting then
					return
				end
				state.fields.labels = selected
				render_meta(state)
			end,
		})
	end)
end

---@param state ForgeIssueEditorState
local function pick_milestone(state)
	if state.closed or state.is_submitting then
		return
	end
	state.layout.statusline:notify("loading", "Loading milestones...")
	state.requests.run(function(done)
		return state.api.list_milestones(state.fields.repo_slug, done)
	end, function(items, err)
		if state.is_submitting then
			return
		end
		if err or not items then
			state.layout.statusline:notify("error", err or "Failed to load milestones")
			return
		end
		state.layout.statusline:clear_notice()
		local choices = { { id = nil, title = "None" } }
		vim.list_extend(choices, items)
		picker.select({
			title = "Milestone",
			items = choices,
			format_item = function(item)
				return item.title
			end,
			on_select = function(choice)
				if not state.closed and not state.is_submitting and choice then
					state.fields.milestone = choice.id and choice or nil
					render_meta(state)
				end
			end,
		})
	end)
end

---@param state ForgeIssueEditorState
local function pick_due_date(state)
	if state.closed or state.is_submitting then
		return
	end
	vim.ui.input({
		prompt = "Due date (YYYY-MM-DD, empty to clear): ",
		default = state.fields.due_date or "",
	}, function(value)
		if state.closed or state.is_submitting or value == nil then
			return
		end
		value = vim.trim(value)
		if value ~= "" and not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
			state.layout.statusline:notify("warn", "Due date must use YYYY-MM-DD", 1500)
			return
		end
		state.fields.due_date = value ~= "" and value or nil
		render_meta(state)
	end)
end

---@param state ForgeIssueEditorState
---@param result ForgeIssueCreateResult
local function finish(state, result)
	if state.closed then
		return
	end
	local editing = state.issue ~= nil
	close(state)
	complete(state, result, nil)
	notify.info(editing and "Issue updated" or "Issue created", { timeout = 1200 })
end

---@param state ForgeIssueEditorState
local function submit(state)
	if state.closed or state.is_submitting then
		return
	end
	local current = values(state)
	local title = current.title
	if title == "" then
		state.layout.statusline:notify("warn", "Title is required", 1500)
		return
	end
	if state.issue and not is_modified(state) then
		close(state, true)
		notify.info("No changes")
		return
	end
	local labels, assignees = current.labels, current.assignees
	local milestone = current.milestone or nil
	local due_date = state.fields.due_date and (state.fields.due_date .. "T00:00:00Z") or nil
	state.is_submitting = true
	vim.bo[state.layout.editor_buf].modifiable = false
	state.layout.statusline:notify("loading", state.issue and "Updating issue..." or "Creating issue...")

	local function failed(err)
		if state.closed then
			return
		end
		state.is_submitting = false
		vim.bo[state.layout.editor_buf].modifiable = true
		state.layout.statusline:notify("error", tostring(err or "Issue request failed"))
	end

	if not state.issue then
		state.requests.run(function(done)
			return state.api.create({
				repo_slug = state.fields.repo_slug,
				title = title,
				body = current.body,
				labels = labels,
				assignees = assignees,
				milestone = milestone,
				due_date = due_date,
			}, done)
		end, function(result, err)
			if err or not result then
				failed(err or "Invalid create issue response")
				return
			end
			finish(state, result)
		end)
		return
	end

	state.requests.run(function(done)
		return state.api.update_issue(state.issue, {
			title = title,
			body = current.body,
			assignees = assignees,
			milestone = milestone or 0,
			due_date = due_date,
			unset_due_date = due_date == nil,
		}, done)
	end, function(updated, err)
		if err or not updated then
			failed(err or "Invalid update issue response")
			return
		end
		state.issue = updated
		local result = {
			number = updated.number,
			key = updated.key,
			url = updated.url,
			issue = updated,
		}
		if vim.deep_equal(labels, state.initial.labels) then
			finish(state, result)
			return
		end
		state.requests.run(function(done)
			return state.api.update_labels(state.issue, labels, done)
		end, function(ok, label_err)
			if not ok then
				failed(label_err or "Issue updated, but labels could not be updated")
				return
			end
			finish(state, result)
		end)
	end)
end

---@param opts ForgeIssueEditorOpts
---@param service ForgeService
---@param api ForgeIssuesApi
local function open(opts, service, api)
	highlights.setup()

	local labels, assignees, milestone, due_date, initial_body = {}, {}, nil, nil, ""
	if opts.details then
		labels = vim.deepcopy(opts.details.labels)
		assignees = vim.deepcopy(opts.details.assignees)
		milestone = vim.deepcopy(opts.details.milestone)
		initial_body = opts.details.description
		due_date = opts.details.due_date and opts.details.due_date:match("^%d%d%d%d%-%d%d%-%d%d") or nil
	end
	---@type ForgeIssueEditorState
	local state = {
		fields = {
			repo_slug = opts.repo_slug,
			labels = labels,
			assignees = assignees,
			milestone = milestone,
			due_date = due_date,
		},
		issue = opts.issue,
		provider_name = service.name,
		api = api,
		users = service.users,
		layout = {},
		is_submitting = false,
		closed = false,
		completed = false,
		requests = request_scope.new(),
		on_done = opts.on_done,
	}

	state.initial = values(state, {
		title = (opts.details and opts.details.title) or (opts.issue and opts.issue.title) or "",
		body = initial_body,
	})
	state.layout = form.open({
		header = state.provider_name .. " Issue",
		initial_title = state.initial.title,
		is_modified = function(editor)
			return not vim.deep_equal(values(state, form.get_content(editor)), state.initial)
		end,
		completion = {
			context = {
				provider = service.id,
				repository = opts.repo_slug,
				issue = opts.issue and { key = opts.issue.key },
			},
		},
		initial_body = initial_body,
		close = function()
			confirm_close(state)
		end,
		on_closed = function()
			close(state, true)
		end,
		submit = function()
			submit(state)
		end,
		meta = function()
			return meta_rows(state)
		end,
		keymaps = {
			{
				key = "ga",
				mode = "n",
				desc = "assignees",
				action = function()
					pick_assignees(state)
				end,
			},
			{
				key = "gl",
				mode = "n",
				desc = "labels",
				action = function()
					pick_labels(state)
				end,
			},
			{
				key = "gm",
				mode = "n",
				desc = "milestone",
				action = function()
					pick_milestone(state)
				end,
			},
			{
				key = "gd",
				mode = "n",
				desc = "due date",
				action = function()
					pick_due_date(state)
				end,
			},
		},
	})

	vim.schedule(function()
		if not state.closed and vim.api.nvim_get_current_buf() == state.layout.editor_buf then
			vim.cmd("startinsert!")
		end
	end)
	return state.layout
end

---@param service ForgeService
---@param api ForgeIssuesApi
---@return ForgeIssueEditor
function M.new(service, api)
	return {
		open = function(repo_slug, on_done)
			return open({ repo_slug = repo_slug, on_done = on_done }, service, api)
		end,
		edit = function(issue, on_done)
			notify.loading("Loading " .. issue.key .. "...")
			return api.get(issue, { force_refresh = true }, function(details, err)
				if not details then
					err = err or "Unable to load issue"
					notify.error(err)
					if on_done then
						on_done(nil, err)
					end
					return
				end
				notify.clear()
				local current = vim.tbl_extend("force", {}, issue)
				if service.id == "gitea" then
					current.content_version = details.content_version
				end
				open(
					{ repo_slug = issue.repo_full_name, issue = current, details = details, on_done = on_done },
					service,
					api
				)
			end)
		end,
	}
end

return M
